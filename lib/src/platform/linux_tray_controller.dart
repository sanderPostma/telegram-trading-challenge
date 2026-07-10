import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../logging/app_log.dart';

/// Keeps the Linux app alive in the system tray while its window is hidden.
class LinuxTrayController with TrayListener, WindowListener {
  LinuxTrayController._();

  static final LinuxTrayController instance = LinuxTrayController._();

  bool _enabled = false;
  bool _quitting = false;

  Future<void> initialize() async {
    if ((!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) ||
        _enabled) {
      return;
    }

    windowManager.addListener(this);
    final usesTrayManager = Platform.isWindows || Platform.isMacOS;
    if (usesTrayManager) trayManager.addListener(this);
    try {
      if (usesTrayManager) {
        await trayManager.setIcon(
          Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
        );
        await trayManager.setToolTip('Telegram Trading Challenge');
        await trayManager.setContextMenu(
          Menu(
            items: [
              MenuItem(key: 'show_window', label: 'Show Trading Challenge'),
              MenuItem.separator(),
              MenuItem(key: 'quit', label: 'Quit'),
            ],
          ),
        );
      }
      await windowManager.setPreventClose(true);
      _enabled = true;
      unawaited(
        AppLog.write(
          usesTrayManager
              ? 'Desktop system tray initialized.'
              : 'Linux system tray window behavior initialized.',
        ),
      );
    } catch (error, stackTrace) {
      if (usesTrayManager) trayManager.removeListener(this);
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
    unawaited(AppLog.write('Window hidden to the desktop system tray.'));
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApplication() async {
    if (_quitting) return;
    _quitting = true;
    unawaited(AppLog.write('Application exit confirmed by the user.'));
    if (Platform.isLinux && _enabled) {
      await windowManager.setPreventClose(false);
    }
    if (Platform.isWindows || Platform.isMacOS) {
      await trayManager.destroy();
    }
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        unawaited(_showWindow());
        break;
      case 'quit':
        unawaited(exitApplication());
        break;
    }
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
