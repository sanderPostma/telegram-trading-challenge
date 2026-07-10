import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import '../logging/app_log.dart';

/// Keeps the Linux app alive in the system tray while its window is hidden.
class LinuxTrayController with WindowListener {
  LinuxTrayController._();

  static final LinuxTrayController instance = LinuxTrayController._();

  bool _enabled = false;
  bool _quitting = false;

  Future<void> initialize() async {
    if (!Platform.isLinux || _enabled) return;

    windowManager.addListener(this);
    try {
      await windowManager.setPreventClose(true);
      _enabled = true;
      unawaited(AppLog.write('Linux system tray window behavior initialized.'));
    } catch (error, stackTrace) {
      windowManager.removeListener(this);
      await AppLog.write(
        'Failed to initialize the Linux system tray.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> minimizeToTray() async {
    if (!_enabled) {
      await windowManager.minimize();
      return;
    }
    await _hideWindow();
  }

  Future<void> _hideWindow() async {
    if (!_enabled || _quitting) return;
    await windowManager.hide();
    unawaited(AppLog.write('Window hidden to the Linux system tray.'));
  }

  Future<void> exitApplication() async {
    if (_quitting) return;
    _quitting = true;
    unawaited(AppLog.write('Application exit confirmed by the user.'));
    if (Platform.isLinux && _enabled) {
      await windowManager.setPreventClose(false);
    }
    await windowManager.destroy();
  }

  @override
  void onWindowMinimize() {
    unawaited(_hideWindow());
  }

  @override
  void onWindowClose() {
    unawaited(_hideWindow());
  }
}
