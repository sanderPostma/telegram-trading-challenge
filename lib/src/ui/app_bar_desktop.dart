import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';

PreferredSizeWidget tmgAppBar({
  required String title,
  required List<Widget> actions,
  Widget? leading,
  bool isLive = false,
}) {
  final desktop =
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;
  if (!desktop) {
    // Mobile/standard AppBar: keep the profile switcher (`leading`) — without
    // it there's no way to switch environments on a phone. Give it room.
    return AppBar(
      backgroundColor: isLive ? Brand.gold : null,
      foregroundColor: isLive ? Brand.bg : null,
      automaticallyImplyLeading: false,
      leading: leading,
      leadingWidth: leading == null ? null : 150,
      titleSpacing: 8,
      title: Text(title, overflow: TextOverflow.ellipsis),
      actions: actions,
    );
  }
  return _AppTitleBar(
    title: title,
    actions: actions,
    leading: leading,
    isLive: isLive,
  );
}

/// Integrated title bar: draggable, double-tap to maximize, with min/max/close
/// controls. Mirrors the server-catalog app's title bar. When [isLive] the
/// whole bar turns gold so a live system stands out.
class _AppTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const _AppTitleBar({
    required this.title,
    this.actions = const [],
    this.leading,
    this.isLive = false,
  });

  final String title;
  final List<Widget> actions;
  final Widget? leading;
  final bool isLive;
  static const double _height = 44;
  // Gold used across the LIVE indicator surfaces.
  static const Color _liveColor = Brand.gold;

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isLive
        ? _liveColor
        : (theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface);
    final fg = isLive
        ? Brand.bg
        : (theme.appBarTheme.foregroundColor ?? theme.colorScheme.onSurface);
    return Material(
      color: bg,
      child: SizedBox(
        height: _height,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(
                'assets/app-logo.jpg',
                width: 22,
                height: 22,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(color: fg),
            ),
            if (leading != null) ...[const SizedBox(width: 14), leading!],
            Expanded(
              child: DragToMoveArea(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            ...actions,
            const SizedBox(width: 4),
            _WindowControls(foreground: fg),
          ],
        ),
      ),
    );
  }
}

class _WindowControls extends StatefulWidget {
  const _WindowControls({required this.foreground});
  final Color foreground;
  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _max = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowButton(
          icon: Icons.remove,
          tooltip: 'Minimize',
          color: widget.foreground,
          onPressed: () => windowManager.minimize(),
        ),
        _WindowButton(
          icon: _max ? Icons.filter_none : Icons.crop_square,
          iconSize: _max ? 13 : 15,
          tooltip: _max ? 'Restore' : 'Maximize',
          color: widget.foreground,
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _WindowButton(
          icon: Icons.close,
          tooltip: 'Close',
          color: widget.foreground,
          hoverColor: Colors.red.shade600,
          hoverForeground: Colors.white,
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    this.iconSize = 17,
    this.hoverColor,
    this.hoverForeground,
  });
  final IconData icon;
  final String tooltip;
  final Color color;
  final double iconSize;
  final Color? hoverColor;
  final Color? hoverForeground;
  final VoidCallback onPressed;
  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.hoverColor ?? widget.color.withValues(alpha: 0.12);
    final fg = _hover && widget.hoverForeground != null
        ? widget.hoverForeground!
        : widget.color;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 44,
            height: 44,
            color: _hover ? hoverBg : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
  }
}
