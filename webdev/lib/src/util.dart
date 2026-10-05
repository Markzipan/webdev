// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:stack_trace/stack_trace.dart';

const appName = 'webdev';

/// Handles [requests] using [handler].
///
/// Captures all sync and async stack error traces and passes
/// them to the [onError] handler.
void serveHttpRequests(
  Stream<HttpRequest> requests,
  Handler handler,
  void Function(Object, StackTrace) onError,
) {
  return Chain.capture(() {
    serveRequests(requests, handler);
  }, onError: onError);
}

/// The path to the root directory of the SDK.
final String sdkDir = (() {
  final runningSdk = p.dirname(p.dirname(Platform.resolvedExecutable));
  if (File(p.join(runningSdk, 'version')).existsSync()) return runningSdk;
  final String dartExecutable = Platform.isWindows
      // Use 'where.exe' to support powershell as well
      ? (Process.runSync('where.exe', ['dart.exe']).stdout as String)
            .split(RegExp('(\r\n|\r|\n)'))
            .first
      : Process.runSync('which', ['dart']).stdout;
  final pathToSdk = p.dirname(p.dirname(dartExecutable));
  assert(FileSystemEntity.isFileSync(p.join(pathToSdk, 'version')));
  return pathToSdk;
})();
final String dartPath = p.join(sdkDir, 'bin', 'dart');
final String devToolsPath = p.join(sdkDir, 'bin', 'resources', 'devtools');
