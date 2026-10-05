// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:dwds/data/build_result.dart';
import 'package:dwds/dwds.dart';
import 'package:frontend_server_client/frontend_server_client.dart';
import 'package:logging/logging.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

const appScheme = 'org-dartlang-app';
final _logger = Logger('FrontendServer');

/// The modification time of a missing file.
final _missing = DateTime.fromMillisecondsSinceEpoch(0);

const _debounceDuration = Duration(milliseconds: 100);

class FrontendServerCompiler {
  final DartDevcFrontendServerClient client;
  final String packageRoot;

  /// Relative to [packageRoot].
  final String entrypoint;

  final PackageConfig _packageConfig;
  final List<String> _localRoots;
  final bool _autoHotReload;

  final _buildResults = StreamController<BuildResult>.broadcast();
  final _watcherSubscriptions = <StreamSubscription<WatchEvent>>[];
  Timer? _debounceTimer;

  /// Maps a source file to the last time it was up to date.
  final _sources = <String, DateTime>{};

  /// The Dart files the watcher reported since the last compile.
  final _changedPaths = <String>{};

  /// True if the latest compile had errors.
  bool _hasErrors = false;

  /// Holds hot reload rejection messages.
  ///
  /// Cleared when the app hot restarts or reloads.
  String? hotReloadRejection;

  /// Maps a source file to its not-yet-loaded `reloaded_sources.json` entry.
  final reloadedSources = <String, Map<String, Object>>{};

  /// True if [reloadedSources] were served, so the next compile replaces them.
  bool reloadedSourcesServed = false;

  Future<bool> _lastUpdate = Future.value(true);
  bool _isDisposed = false;

  FrontendServerCompiler._(
    this.client,
    this.packageRoot,
    this.entrypoint,
    this._packageConfig,
    this._localRoots,
    this._autoHotReload,
  );

  static Future<FrontendServerCompiler> start({
    required String packageRoot,
    required String entrypoint,
    required String packageConfigPath,
    required String sdkDir,
    required String outputDir,
    List<String> experiments = const [],
    bool? deprecatedJsInterop,
    bool autoHotReload = false,
  }) async {
    final packageConfig = await loadPackageConfig(File(packageConfigPath));
    // The Frontend Server starts from its last output, so clear that when the
    // compile options change.
    final optionsFile = File(p.join(outputDir, 'options'));
    final options = '$experiments $deprecatedJsInterop';
    if (!optionsFile.existsSync() ||
        optionsFile.readAsStringSync() != options) {
      if (Directory(outputDir).existsSync()) {
        Directory(outputDir).deleteSync(recursive: true);
      }
      optionsFile
        ..createSync(recursive: true)
        ..writeAsStringSync(options);
    }
    final client = await DartDevcFrontendServerClient.start(
      '$appScheme:///$entrypoint',
      p.join(outputDir, 'app.dill'),
      dartdevcModuleFormat: 'ddc',
      canaryFeatures: true,
      enabledExperiments: experiments,
      fileSystemRoots: [Directory(packageRoot).uri.toFilePath()],
      fileSystemScheme: appScheme,
      packagesJson: packageConfigPath,
      sdkRoot: sdkDir,
      additionalArgs: [
        if (deprecatedJsInterop != null)
          '--${deprecatedJsInterop ? '' : 'no-'}deprecated-js-interop',
      ],
    );
    // The package and its path deps (without nested roots).
    final roots = {
      p.normalize(packageRoot),
      for (final package in packageConfig.packages)
        if (package.relativeRoot) p.normalize(p.fromUri(package.root)),
    };
    final compiler = FrontendServerCompiler._(
      client,
      packageRoot,
      entrypoint,
      packageConfig,
      [
        for (final root in roots)
          if (!roots.any((other) => p.isWithin(other, root))) root,
      ],
      autoHotReload,
    );
    await compiler._initialCompile();
    compiler._watch();
    return compiler;
  }

  Stream<BuildResult> get buildResults => _buildResults.stream;

  /// Returns a source file at given its [serverPath].
  File? sourceFile(String serverPath) {
    final segments = p.url.split(serverPath).where((s) => s != '/').toList();
    if (segments.length > 2 && segments.first == 'packages') {
      final fileUri = _packageConfig.resolve(
        Uri(scheme: 'package', pathSegments: segments.skip(1)),
      );
      return fileUri == null ? null : File(p.fromUri(fileUri));
    }
    final path = p.normalize(p.joinAll([packageRoot, ...segments]));
    return p.isWithin(packageRoot, path) ? File(path) : null;
  }

  /// Recompiles the app if any of its local sources changed.
  ///
  /// Returns whether the app compiled without errors.
  Future<bool> update({bool forRestart = false}) {
    _debounceTimer?.cancel();
    return _lastUpdate = _lastUpdate
        .then((_) => _update(forRestart))
        .catchError((Object e, StackTrace s) {
          if (!_isDisposed) _logger.severe('Failed to compile.', e, s);
          return false;
        });
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _debounceTimer?.cancel();
    await Future.wait([
      for (final subscription in _watcherSubscriptions) subscription.cancel(),
    ]);
    await client.shutdown();
    await _buildResults.close();
  }

  Future<void> _initialCompile() async {
    _logger.info('Compiling $entrypoint with the Frontend Server...');
    final stopwatch = Stopwatch()..start();
    final compileStart = DateTime.now();
    final result = await client.compile();
    if (result.dillOutput == null) {
      throw StateError(
        'The Frontend Server failed to compile $entrypoint:\n'
        '${result.compilerOutputLines.join('\n')}',
      );
    }
    // Accept even with errors, as later compiles are incremental.
    client.accept();
    _updateSources(result, compileStart);
    if (result.errorCount > 0) {
      _hasErrors = true;
      _logger.severe('Failed to compile $entrypoint:\n${_errors(result)}');
    } else {
      _logger.info(
        'Compiled $entrypoint in ${stopwatch.elapsedMilliseconds}ms.',
      );
    }
  }

  Future<bool> _update(bool forRestart) async {
    if (_isDisposed) return false;
    // The client also recompiles the uris of rejected compiles.
    final invalidated = _invalidatedUris();
    if (invalidated.isEmpty) return !_hasErrors;

    final stopwatch = Stopwatch()..start();
    final compileStart = DateTime.now();
    _buildResults.add(BuildResult(status: BuildStatus.started));
    String? rejection;
    var result = forRestart
        ? await client.recompileRestart(invalidated)
        : await client.compile(invalidated);
    if (_isDisposed) return false;
    if (result.errorCount > 0 && !forRestart) {
      // Hot reload rejections may be fine for a hot restart.
      await client.reject();
      final restartResult = await client.recompileRestart(invalidated);
      if (_isDisposed) return false;
      if (restartResult.errorCount == 0) rejection = _errors(result);
      result = restartResult;
    }
    if (result.errorCount > 0) {
      await client.reject();
      _hasErrors = true;
      _logger.severe('Failed to compile $entrypoint:\n${_errors(result)}');
      _buildResults.add(BuildResult(status: BuildStatus.failed));
      return false;
    }

    client.accept();
    _hasErrors = false;
    _updateSources(result, compileStart);
    if (reloadedSourcesServed) reloadedSources.clear();
    reloadedSourcesServed = false;
    for (final entry in client.reloadedSources) {
      reloadedSources[entry['src'] as String] = entry;
    }
    if (rejection != null) {
      hotReloadRejection = rejection;
      _logger.warning(rejection);
    }
    _logger.info('Compiled $entrypoint in ${stopwatch.elapsedMilliseconds}ms.');
    // Don't auto hot reload rejected changes.
    final status = rejection != null && _autoHotReload
        ? BuildStatus.failed
        : BuildStatus.succeeded;
    _buildResults.add(BuildResult(status: status));
    return true;
  }

  /// URIs of locally changed files.
  List<Uri> _invalidatedUris() {
    final changed = <String, DateTime>{};
    for (final MapEntry(key: path, value: upToDate) in _sources.entries) {
      final stat = FileStat.statSync(path);
      final modified = stat.type == FileSystemEntityType.notFound
          ? _missing
          : stat.modified;
      final isChanged = modified == _missing
          ? upToDate != _missing
          : modified.isAfter(upToDate);
      if (isChanged) changed[path] = modified;
    }
    _sources.addAll(changed);
    final paths = {...changed.keys, if (_hasErrors) ..._changedPaths};
    _changedPaths.clear();
    return [for (final path in paths) _compilerUriFor(path)];
  }

  /// Converts [path] to the URI understood by the Frontend Server.
  Uri _compilerUriFor(String path) {
    final fileUri = p.toUri(path);
    final packageUri = _packageConfig.toPackageUri(fileUri);
    if (packageUri != null) return packageUri;
    if (p.isWithin(packageRoot, path)) {
      final relativePath = p.split(p.relative(path, from: packageRoot));
      return Uri.parse('$appScheme:///${p.url.joinAll(relativePath)}');
    }
    return fileUri;
  }

  void _updateSources(CompileResult result, DateTime compileStart) {
    for (final uri in result.removedSources) {
      if (uri.isScheme('file')) _sources.remove(p.fromUri(uri));
    }
    for (final uri in result.newSources) {
      if (!uri.isScheme('file')) continue;
      final path = p.fromUri(uri);
      if (_localRoots.any((root) => p.isWithin(root, path))) {
        _sources.putIfAbsent(path, () => compileStart);
      }
    }
  }

  void _watch() {
    for (final root in _localRoots) {
      _watcherSubscriptions.add(
        DirectoryWatcher(root).events.listen(
          (event) {
            final segments = p.split(p.relative(event.path, from: root));
            // Ignore `build` and hidden directories like `.dart_tool`.
            if (!event.path.endsWith('.dart') ||
                segments.first == 'build' ||
                segments.any((segment) => segment.startsWith('.'))) {
              return;
            }
            _changedPaths.add(p.normalize(event.path));
            _debounceTimer?.cancel();
            _debounceTimer = Timer(
              _debounceDuration,
              () => unawaited(update()),
            );
          },
          onError: (Object e, StackTrace s) {
            _logger.warning('Error watching $root for changes.', e, s);
          },
        ),
      );
    }
  }

  /// [result]'s errors after a failed hot reload (without stack trace).
  static String _errors(CompileResult result) => result.compilerOutputLines
      .takeWhile((line) => !line.startsWith('#0 '))
      .join('\n');
}

class FrontendServerExpressionCompiler implements ExpressionCompiler {
  final DartDevcFrontendServerClient _client;

  FrontendServerExpressionCompiler(this._client);

  @override
  Future<ExpressionCompilationResult> compileExpressionToJs(
    String isolateId,
    String libraryUri,
    String scriptUri,
    int line,
    int column,
    Map<String, String> jsModules,
    Map<String, String> jsFrameValues,
    String moduleName,
    String expression,
  ) async {
    final result = await _client.compileExpressionToJs(
      expression: expression,
      column: column,
      jsFrameValues: jsFrameValues,
      jsModules: jsModules,
      libraryUri: libraryUri,
      line: line,
      moduleName: moduleName,
      scriptUri: scriptUri,
    );
    return ExpressionCompilationResult(
      result.compiledExpression ?? result.compilerOutputLines.join('\n'),
      result.compiledExpression == null,
    );
  }

  @override
  Future<bool> updateDependencies(Map<String, ModuleInfo> modules) async =>
      true;

  @override
  Future<void> initialize(CompilerOptions options) async {}
}
