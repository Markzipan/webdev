// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dwds/src/services/expression_compiler.dart';
import 'package:dwds/src/utilities/sdk_configuration.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

class _Compiler {
  static final _logger = Logger('ExpressionCompilerService');
  final StreamQueue<Map<String, dynamic>> _responseQueue;
  final Process _process;

  final _sendPool = Pool(1);
  Future<void>? _dependencyUpdate;

  _Compiler._(this._responseQueue, this._process);

  /// Sends [request] on _process.stdin and returns the next event from the
  /// response stream.
  Future<Map<String, dynamic>> _send(Map<String, Object> request) async {
    return _sendPool.withResource(() async {
      _process.stdin.writeln(jsonEncode(request));
      await _process.stdin.flush();
      if (!await _responseQueue.hasNext) {
        return {
          'succeeded': false,
          'errors': ['compilation worker response stream closed'],
        };
      }
      return await _responseQueue.next;
    });
  }

  /// Starts expression compilation service.
  ///
  /// Starts expression compiler worker as a subprocess using Dart CLI and creates the
  /// expression compilation service that communicates to the worker.
  ///
  /// [sdkConfiguration] describes the locations of SDK files used in
  /// expression compilation (summaries, libraries spec).
  ///
  /// Users need to stop the service by calling [stop].
  static Future<_Compiler> start(
    String address,
    int port,
    SdkConfiguration sdkConfiguration,
    CompilerOptions compilerOptions,
    bool verbose,
  ) async {
    sdkConfiguration.validateSdkDir();
    sdkConfiguration.validateSummaries();

    final sdkSummaryUri = sdkConfiguration.sdkSummaryUri!;

    final dartExecutable = p.join(
      sdkConfiguration.sdkDirectory!,
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );

    final args = [
      'compile',
      'js-dev',
      '--experimental-expression-compiler',
      '--dart-sdk-summary',
      '$sdkSummaryUri',
      '--asset-server-address',
      address,
      '--asset-server-port',
      '$port',
      '--module-format',
      compilerOptions.moduleFormat.name,
      if (verbose) '--verbose',
      for (final experiment in compilerOptions.experiments)
        '--enable-experiment=$experiment',
      if (compilerOptions.canaryFeatures) '--canary',
    ];

    _logger.info('Starting...');
    _logger.finest('$dartExecutable ${args.join(' ')}');

    final process = await Process.start(dartExecutable, args);

    // Stream process errors to stderr or log them.
    process.stderr.transform(utf8.decoder).listen((error) {
      _logger.warning('Expression compiler worker error: $error');
    });

    final responseStream = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) {
          try {
            return jsonDecode(line) as Map<String, dynamic>;
          } catch (e) {
            _logger.warning('Failed to decode response: $line', e);
            return {
              'succeeded': false,
              'errors': ['Failed to decode response: $line'],
            };
          }
        });

    final responseQueue = StreamQueue(responseStream);

    final service = _Compiler._(responseQueue, process);

    return service;
  }

  Future<bool> updateDependencies(Map<String, ModuleInfo> modules) async {
    final updateCompleter = Completer<void>();
    _dependencyUpdate = updateCompleter.future;

    _logger.info('Updating dependencies...');
    _logger.finest('Dependencies: $modules');

    final response = await _send({
      'command': 'UpdateDeps',
      'inputs': [
        for (final moduleName in modules.keys)
          {
            'path': modules[moduleName]!.fullDillPath,
            'summaryPath': modules[moduleName]!.summaryPath,
            'moduleName': moduleName,
          },
      ],
    });
    final result = (response['succeeded'] as bool?) ?? false;
    if (result) {
      _logger.info('Updated dependencies.');
    } else {
      final errors = response['errors'];
      final exception = response['exception'];
      final s = response['stackTrace'] as String?;
      final stackTrace = s == null ? null : StackTrace.fromString(s);
      _logger.severe(
        'Failed to update dependencies: $errors',
        exception,
        stackTrace,
      );
    }
    updateCompleter.complete();
    return result;
  }

  Future<ExpressionCompilationResult> compileExpressionToJs(
    String libraryUri,
    String scriptUri,
    int line,
    int column,
    Map<String, String> jsModules,
    Map<String, String> jsFrameValues,
    String moduleName,
    String expression,
  ) async {
    _logger.finest('Waiting for dependencies to update');
    if (_dependencyUpdate == null) {
      _logger.warning(
        'Dependencies are not updated before compiling expressions',
      );
      return ExpressionCompilationResult('<compiler is not ready>', true);
    }

    await _dependencyUpdate;

    _logger.finest('Compiling "$expression" at $libraryUri:$line');

    final response = await _send({
      'command': 'CompileExpression',
      'expression': expression,
      'line': line,
      'column': column,
      'jsModules': jsModules,
      'jsScope': jsFrameValues,
      'libraryUri': libraryUri,
      'scriptUri': scriptUri,
      'moduleName': moduleName,
    });

    final error = _createErrorMsg(response);
    final procedure = (response['compiledProcedure'] as String?) ?? '';
    final succeeded = (response['succeeded'] as bool?) ?? false;
    final result = succeeded ? procedure : error;

    if (succeeded) {
      _logger.finest('Compiled "$expression" to: $result');
    } else {
      _logger.finest('Failed to compile "$expression": $result');
    }
    return ExpressionCompilationResult(result, !succeeded);
  }

  String _createErrorMsg(Map<String, dynamic> response) {
    final errors = response['errors'] as List<dynamic>?;
    if (errors != null && errors.isNotEmpty) return errors.first.toString();

    final e = response['exception'];
    final s = response['stackTrace'];
    return e != null ? '$e:$s' : '<unknown error>';
  }

  /// Stops the service.
  ///
  /// Terminates the subprocess running expression compiler worker
  /// and marks the service as stopped.
  Future<void> stop() async {
    _process.stdin.writeln(jsonEncode({'command': 'Shutdown'}));
    await _process.stdin.flush();
    await _process.exitCode;
    _logger.info('Stopped.');
  }
}

/// Service that handles expression compilation requests.
///
/// Expression compiler service spawns a dartdevc in expression compilation
/// mode in a subprocess and communicates with it via stdin/stdout.
/// It also handles full dill file read requests from the subprocess
/// and redirects them to the asset server.
///
/// Uses [_address] and [_port] to communicate and to redirect asset
/// requests to the asset server.
///
/// Configuration created by [sdkConfigurationProvider] describes the
/// locations of SDK files used in expression compilation (summaries,
/// libraries spec).
///
/// Users need to stop the service by calling [stop].
class ExpressionCompilerService implements ExpressionCompiler {
  final _compiler = Completer<_Compiler>();
  final String _address;
  final FutureOr<int> _port;
  final bool _verbose;

  final SdkConfigurationProvider sdkConfigurationProvider;

  ExpressionCompilerService(
    this._address,
    this._port, {
    this._verbose = false,
    required this.sdkConfigurationProvider,
  });

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
  ) async => (await _compiler.future).compileExpressionToJs(
    libraryUri,
    scriptUri,
    line,
    column,
    jsModules,
    jsFrameValues,
    moduleName,
    expression,
  );

  @override
  Future<void> initialize(CompilerOptions options) async {
    if (_compiler.isCompleted) return;

    final compiler = await _Compiler.start(
      _address,
      await _port,
      await sdkConfigurationProvider.configuration,
      options,
      _verbose,
    );

    _compiler.complete(compiler);
  }

  @override
  Future<bool> updateDependencies(Map<String, ModuleInfo> modules) async =>
      (await _compiler.future).updateDependencies(modules);

  Future<void> stop() async {
    if (_compiler.isCompleted) {
      await (await _compiler.future).stop();
    }
  }
}
