import 'dart:io';

import 'package:flutter/foundation.dart';

class AppLog {
  static const _fileName = 'trading_challenge.log';
  static File? _file;
  static Future<File>? _fileFuture;
  static String? _path;

  static String get path => _path ?? _defaultLogFilePath();

  static Future<void> startSession() async {
    await write('App session started.');
  }

  static Future<void> write(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final timestamp = DateTime.now().toIso8601String();
    final buffer = StringBuffer('$timestamp  $message\n');
    if (error != null) {
      buffer.writeln('error: $error');
    }
    if (stackTrace != null) {
      buffer.writeln('stack:');
      buffer.writeln(stackTrace);
    }
    await _append(buffer.toString());
    debugPrint(message);
  }

  static Future<void> _append(String text) async {
    try {
      final file = await _logFile();
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (error) {
      debugPrint('Log write failed: $error');
    }
  }

  static Future<File> _logFile() {
    final existing = _file;
    if (existing != null) return Future.value(existing);
    return _fileFuture ??= _createLogFile();
  }

  static Future<File> _createLogFile() async {
    final path = _defaultLogFilePath();
    _path = path;
    final file = File(path);
    await file.parent.create(recursive: true);
    _file = file;
    return file;
  }

  static String _defaultLogFilePath() {
    final separator = Platform.pathSeparator;
    final base = _baseLogDirectory();
    return '$base$separator$_fileName';
  }

  static String _baseLogDirectory() {
    final env = Platform.environment;
    if (Platform.isLinux) {
      final stateHome = env['XDG_STATE_HOME'];
      if (stateHome != null && stateHome.isNotEmpty) {
        return _join(stateHome, 'trading_challenge');
      }
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return _join(
          _join(home, '.local'),
          _join('state', 'trading_challenge'),
        );
      }
    }
    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) {
        return _join(
          _join(home, 'Library'),
          _join('Logs', 'Trading Challenge'),
        );
      }
    }
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return _join(_join(localAppData, 'TradingChallenge'), 'logs');
      }
    }
    return _join(Directory.systemTemp.path, 'trading_challenge');
  }

  static String _join(String left, String right) {
    if (left.endsWith(Platform.pathSeparator)) return '$left$right';
    return '$left${Platform.pathSeparator}$right';
  }
}
