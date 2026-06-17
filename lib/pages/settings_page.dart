import 'package:flutter/material.dart';

import '../app_navigation.dart';
import '../widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppPageShell(
      title: '设置',
      bottomNavigationBar: AppTabBar(
        active: AppTab.settings,
        onChanged: (tab) => openAppTab(context, tab, active: AppTab.settings),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 126),
        children: const [
          AppSectionLabel('播放'),
          AppGroupedList(
            children: [
              _SettingsRow(
                icon: Icons.high_quality_outlined,
                title: '画质',
                subtitle: '默认使用原始画质',
              ),
              AppListDivider(),
              _SettingsRow(
                icon: Icons.screen_rotation_alt_outlined,
                title: '播放方向',
                subtitle: '播放时自动横屏',
              ),
            ],
          ),
          AppSectionLabel('应用'),
          AppGroupedList(
            children: [
              _SettingsRow(
                icon: Icons.info_outline,
                title: '版本',
                subtitle: '0.1.0',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 17),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: appAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: appAccent),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: appTextPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: appTextMuted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
