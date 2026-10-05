// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dwds/dwds.dart';
import 'package:frontend_server_client/frontend_server_client.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

import 'frontend_server_compiler.dart';

const _jsCharsetTag = 'application/javascript; charset=utf-8';
const _jsonCharsetTag = 'application/json; charset=utf-8';

const _bootstrapPath = 'main.dart.js';
const _mainModulePath = 'main_module.bootstrap.js';
const _onLoadEndPath = 'on_load_end_bootstrap.js';
const _moduleLoaderPath = 'ddc_module_loader.js';
const _stackTraceMapperPath = 'stack_trace_mapper.js';
const _sdkPath = 'dart_sdk.js';

final _bootstrapScript = utf8.encode(
  generateDdcLibraryBundleBootstrapScript(
    ddcModuleLoaderUrl: _moduleLoaderPath,
    mapperUrl: _stackTraceMapperPath,
    sdkUrl: _sdkPath,
    mainModuleUrl: _mainModulePath,
  ),
);
final _onLoadEndScript = utf8.encode(
  generateDdcLibraryBundleOnLoadEndBootstrap(),
);

/// Loads the modules in [mergedMetadata] relative to the page.
String _loadModules(String mergedMetadata) {
  final scripts = [
    for (final line in const LineSplitter().convert(mergedMetadata))
      if (line.isNotEmpty)
        if (jsonDecode(line) case {
          'name': final String name,
          'moduleUri': final String moduleUri,
        })
          {'src': moduleUri.replaceFirst(RegExp('^/+'), ''), 'id': name},
  ];
  return '''
var scripts = ${jsonEncode(scripts)};
window.\$dartLoader.loadConfig.loadScriptFn = function(loader) {
  loader.addScriptsToQueue(scripts, null);
  loader.loadEnqueuedModules();
};
window.\$dartLoader.loader.nextAttempt();
''';
}

/// Serves an app compiled by a [FrontendServerCompiler].
class FrontendServerAppHandler {
  final FrontendServerCompiler _compiler;
  final DdcLibraryBundleSdkAssets _sdkAssets;
  final String _reloadedSourcesPath;
  final bool _injectedClient;
  final Handler _staticHandler;
  final _etags = Expando<String>();

  FrontendServerAppHandler(
    this._compiler,
    this._sdkAssets, {
    required String target,
    required this._reloadedSourcesPath,
    required this._injectedClient,
  }) : _staticHandler = createStaticHandler(
         p.join(_compiler.packageRoot, target),
         defaultDocument: 'index.html',
       );

  Future<Response> call(Request request) async {
    final path = request.url.path;
    if (path == _reloadedSourcesPath) {
      await _compiler.update();
      _compiler.reloadedSourcesServed = true;
      return Response.ok(
        jsonEncode(_compiler.reloadedSources.values.toList()),
        headers: {
          HttpHeaders.contentTypeHeader: _jsonCharsetTag,
          HttpHeaders.cacheControlHeader: 'no-store',
        },
      );
    }
    if (path == _bootstrapPath) {
      await _compiler.update(forRestart: true);
      _compiler
        ..reloadedSourcesServed = true
        ..hotReloadRejection = null;
      return _response(request, _bootstrapScript);
    }
    if (path == _mainModulePath) {
      final mainModule = generateDdcLibraryBundleMainModule(
        entrypoint: '$appScheme:///${_compiler.entrypoint}',
        onLoadEndBootstrap: _onLoadEndPath,
      );
      return _response(
        request,
        utf8.encode(
          _injectedClient
              ? mainModule
              : '$mainModule\n${_loadModules(_compiler.client.mergedMetadata)}',
        ),
      );
    }
    final asset = switch (path) {
      _moduleLoaderPath => _sdkAssets.moduleLoader,
      _stackTraceMapperPath => _sdkAssets.stackTraceMapper,
      _sdkPath => _sdkAssets.sdkJs,
      '$_sdkPath.map' => _sdkAssets.sdkJsMap,
      _onLoadEndPath => _onLoadEndScript,
      _ => _compiler.client.assetBytes('/$path'),
    };
    if (asset != null) return _response(request, asset);
    if (path.startsWith('packages/') || path.endsWith('.dart')) {
      final file = _compiler.sourceFile(path);
      if (file != null && file.existsSync()) {
        return createFileHandler(file.path, url: path)(request);
      }
    }
    return _staticHandler(request);
  }

  /// Creates a response with body [bytes] to [request], appending content
  /// headers.
  Response _response(Request request, Uint8List bytes) {
    final etag = _etags[bytes] ??= '"${md5.convert(bytes)}"';
    final headers = {
      HttpHeaders.contentTypeHeader: request.url.path.endsWith('.js')
          ? _jsCharsetTag
          : _jsonCharsetTag,
      HttpHeaders.etagHeader: etag,
      HttpHeaders.cacheControlHeader: 'no-cache',
    };
    if (request.headers[HttpHeaders.ifNoneMatchHeader] == etag) {
      return Response.notModified(headers: headers);
    }
    return Response.ok(bytes, headers: headers);
  }
}

/// Reader for the sources and outputs of [_compiler].
class InMemoryAssetReader implements AssetReader {
  final FrontendServerCompiler _compiler;

  InMemoryAssetReader(this._compiler);

  @override
  String get basePath => '';

  @override
  Future<String?> dartSourceContents(String serverPath) async {
    final file = _compiler.sourceFile(serverPath);
    if (file == null || !file.existsSync()) return null;
    return file.readAsString();
  }

  @override
  Future<String?> sourceMapContents(String serverPath) async {
    final path = serverPath.replaceFirst(RegExp('^/+'), '');
    final bytes = _compiler.client.assetBytes('/$path');
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<String?> metadataContents(String serverPath) async =>
      serverPath.endsWith('.ddc_merged_metadata')
      ? _compiler.client.mergedMetadata
      : null;

  @override
  Future<void> close() async {}
}
