import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/bridge/frb_generated.dart';
import 'src/logging/app_log.dart';
import 'src/platform/linux_tray_controller.dart';
import 'src/state/app_controller.dart';
import 'src/theme.dart';
import 'src/ui/app_shell.dart';

Future<void> main() async {
  await runZonedGuarded(_main, (error, stackTrace) async {
    await AppLog.write(
      'Uncaught Dart zone error.',
      error: error,
      stackTrace: stackTrace,
    );
  });
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.startSession();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      AppLog.write(
        'Uncaught Flutter framework error.',
        error: details.exception,
        stackTrace: details.stack,
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      AppLog.write(
        'Uncaught platform dispatcher error.',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return true;
  };
  await windowManager.ensureInitialized();
  await LinuxTrayController.instance.initialize();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1100, 800),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  var rustReady = false;
  try {
    await RustLib.init();
    rustReady = true;
  } catch (error, stackTrace) {
    debugPrint('Rust bridge init failed: $error');
    unawaited(
      AppLog.write(
        'Rust bridge init failed.',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
  final controller = AppController(useRustBridge: rustReady);
  await controller.loadConfig();
  await controller.loadChartData();
  controller.startWeexPriceStream();
  controller.startTelegramMonitor();
  runApp(TradingChallengeApp(controller: controller));
}

class TradingChallengeApp extends StatelessWidget {
  const TradingChallengeApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Telegram Challenge',
          theme: buildTmgTheme(),
          home: AppShell(controller: controller),
        );
      },
    );
  }
}
