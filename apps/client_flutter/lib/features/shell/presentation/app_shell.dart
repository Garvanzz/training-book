import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../library/presentation/library_page.dart';
import '../../plans/presentation/plans_page.dart';
import '../../progress/presentation/progress_page.dart';
import '../../settings/presentation/settings_page.dart';
import '../../today/presentation/today_page.dart';

enum AppDestination { today, plans, library, progress, settings }

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppDestination _selected = AppDestination.today;

  static const _items = <({String label, IconData icon, String title})>[
    (label: '今天', icon: Icons.today_outlined, title: '今天'),
    (label: '计划', icon: Icons.view_timeline_outlined, title: '训练计划'),
    (label: '动作库', icon: Icons.fitness_center_outlined, title: '动作库'),
    (label: '进度', icon: Icons.insights_outlined, title: '进度'),
    (label: '设置', icon: Icons.tune_outlined, title: '设置'),
  ];

  Widget _page() => switch (_selected) {
    AppDestination.today => TodayPage(
      repository: widget.repository,
      onOpenPlans: () => setState(() => _selected = AppDestination.plans),
    ),
    AppDestination.plans => PlansPage(repository: widget.repository),
    AppDestination.library => LibraryPage(repository: widget.repository),
    AppDestination.progress => ProgressPage(repository: widget.repository),
    AppDestination.settings => SettingsPage(repository: widget.repository),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 840;
      final item = _items[_selected.index];
      return Scaffold(
        body: Row(
          children: [
            if (desktop) _DesktopNavigation(selected: _selected, onChanged: (value) => setState(() => _selected = value), repository: widget.repository),
            Expanded(
              child: Column(
                children: [
                  _PageBar(title: item.title),
                  Expanded(child: _page()),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: desktop
            ? null
            : NavigationBar(
                selectedIndex: _selected.index,
                destinations: [
                  for (final item in _items) NavigationDestination(icon: Icon(item.icon), label: item.label),
                ],
                onDestinationSelected: (index) => setState(() => _selected = AppDestination.values[index]),
              ),
      );
    },
  );
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({required this.selected, required this.onChanged, required this.repository});
  final AppDestination selected;
  final ValueChanged<AppDestination> onChanged;
  final TrainingRepository repository;

  @override
  Widget build(BuildContext context) => Container(
    width: 216,
    decoration: const BoxDecoration(border: Border(right: BorderSide(color: AppColors.border))),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 28, 20, 30),
          child: Row(
            children: [
              _BrandMark(),
              SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('训练簿', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              ]),
            ],
          ),
        ),
        for (final destination in AppDestination.values)
          _NavItem(
            label: _AppShellState._items[destination.index].label,
            icon: _AppShellState._items[destination.index].icon,
            selected: selected == destination,
            onTap: () => onChanged(destination),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.all(20),
          child: DecoratedBox(
            decoration: BoxDecoration(color: AppColors.surfaceRaised, borderRadius: BorderRadius.all(Radius.circular(12))),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(
                  !repository.isSignedIn
                      ? Icons.cloud_off_outlined
                      : repository.pendingOperationCount > 0
                      ? Icons.cloud_upload_outlined
                      : Icons.cloud_done_outlined,
                  size: 17,
                  color: !repository.isSignedIn
                      ? AppColors.muted
                      : repository.pendingOperationCount > 0
                      ? AppColors.warning
                      : AppColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  !repository.isSignedIn
                      ? '未登录 · 数据仅在本机'
                      : repository.pendingOperationCount > 0
                      ? '${repository.pendingOperationCount} 条待同步'
                      : '已连接账号',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                )),
              ]),
            ),
          ),
        ),
      ],
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();
  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(9)),
    child: const Icon(Icons.menu_book_rounded, color: AppColors.accentInk, size: 18),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Material(
      color: selected ? AppColors.surfaceInteractive : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(children: [
            Icon(icon, size: 20, color: selected ? AppColors.accent : AppColors.muted),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
      ),
    ),
  );
}

class _PageBar extends StatelessWidget {
  const _PageBar({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Container(
    height: 84,
    padding: const EdgeInsets.symmetric(horizontal: 32),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
    child: Row(children: [
      Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    ]),
  );
}
