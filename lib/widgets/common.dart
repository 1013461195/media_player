import 'package:flutter/material.dart';

const appAccent = Color(0xff18c891);
const appBackground = Color(0xfff4f3f8);
const appTextPrimary = Color(0xff242428);
const appTextMuted = Color(0xff8d8d94);
const appDivider = Color(0xffe7e6eb);

enum AppTab { media, files, servers, settings }

class AppPageShell extends StatelessWidget {
  const AppPageShell({
    required this.title,
    required this.child,
    this.actions = const [],
    this.leading,
    this.subtitle,
    this.bottomNavigationBar,
    this.backgroundColor = appBackground,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottomNavigationBar;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: appTextPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: appTextMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class AppTabBar extends StatelessWidget {
  const AppTabBar({required this.active, required this.onChanged, super.key});

  final AppTab active;
  final ValueChanged<AppTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _AppTabItem(
              active: active,
              tab: AppTab.media,
              icon: Icons.play_circle_outline_rounded,
              label: '媒体库',
              onTap: onChanged,
            ),
            _AppTabItem(
              active: active,
              tab: AppTab.files,
              icon: Icons.folder_outlined,
              label: '文件源',
              onTap: onChanged,
            ),
            _AppTabItem(
              active: active,
              tab: AppTab.servers,
              icon: Icons.dns_outlined,
              label: '影视服务器',
              onTap: onChanged,
            ),
            _AppTabItem(
              active: active,
              tab: AppTab.settings,
              icon: Icons.settings_outlined,
              label: '设置',
              onTap: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppTabItem extends StatelessWidget {
  const _AppTabItem({
    required this.active,
    required this.tab,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final AppTab active;
  final AppTab tab;
  final IconData icon;
  final String label;
  final ValueChanged<AppTab> onTap;

  @override
  Widget build(BuildContext context) {
    final selected = active == tab;
    final color = selected ? appAccent : const Color(0xff5f5f64);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: selected ? null : () => onTap(tab),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppCircleButton extends StatelessWidget {
  const AppCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.filled = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: filled ? appAccent : Colors.white,
        shape: const CircleBorder(),
        elevation: filled ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          iconSize: 22,
          icon: Icon(icon, color: filled ? Colors.white : appTextPrimary),
        ),
      ),
    );
  }
}

class AppSectionLabel extends StatelessWidget {
  const AppSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: const Color(0xff72727a),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class AppGroupedList extends StatelessWidget {
  const AppGroupedList({
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 20),
    super.key,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class AppListDivider extends StatelessWidget {
  const AppListDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 0.8, color: appDivider);
  }
}

class SecondsIcon extends StatelessWidget {
  const SecondsIcon({required this.label, this.forward = false, super.key});

  final String label;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(forward ? -1 : 1, 1, 1),
            child: const Icon(Icons.replay, size: 24),
          ),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class StreamingVideo extends StatelessWidget {
  const StreamingVideo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            const Text('正在打开视频流...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('这里没有可显示的文件夹、图片或视频'));
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    required this.message,
    required this.onRetry,
    this.dark = false,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: color, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              style: TextStyle(color: color),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
