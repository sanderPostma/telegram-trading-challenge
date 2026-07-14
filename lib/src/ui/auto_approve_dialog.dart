import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';

Future<void> handleAutoApproveToggle(
  BuildContext context,
  AppController controller,
  bool value,
) async {
  if (value && !controller.config.hasSeenAutoApproveWarning) {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Brand.danger),
            const SizedBox(width: 8),
            const Text('Caution'),
          ],
        ),
        content: const SizedBox(
          width: 400,
          child: Text(
            'Do not enable Auto-Approve on multiple devices at the same time. '
            'Each device has its own local Telegram deduplication state; there is '
            'currently no shared cross-device lease. Multiple devices can therefore '
            'process the same Telegram message and submit duplicate trades to the same '
            'WEEX account.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            child: const Text('I understand'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      controller.setHasSeenAutoApproveWarning(true);
      controller.setAutoApprove(true);
    }
  } else {
    controller.setAutoApprove(value);
  }
}
