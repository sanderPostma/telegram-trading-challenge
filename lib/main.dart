import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/bridge/frb_generated.dart';
import 'src/state/app_controller.dart';
import 'src/theme.dart';
import 'src/ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
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
  } catch (error) {
    debugPrint('Rust bridge init failed: $error');
  }
  final controller = AppController(useRustBridge: rustReady);
  await controller.loadConfig();
  await controller.loadChartData();
  controller.startWeexPriceStream();
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
