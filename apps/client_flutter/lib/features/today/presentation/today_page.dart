import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../workout/presentation/workout_session_page.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({super.key, required this.repository, this.onOpenPlans});
  final TrainingRepository repository;
  final VoidCallback? onOpenPlans;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  late Future<Map<String, dynamic>?> _active = widget.repository.loadActiveWorkout();

  void _reload() => setState(() => _active = widget.repository.loadActiveWorkout());

  Future<void> _resume(Map<String, dynamic> workout) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => WorkoutSessionPage(repository: widget.repository, workout: workout)));
    if (mounted) _reload();
  }

  Future<void> _abandon(Map<String, dynamic> workout) async {
    final accepted = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('放弃本次训练？'), content: const Text('已记录的组将保留在本机与服务器中，但这次训练不会计入完成历史。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('放弃训练'))]));
    if (accepted != true) return;
    try {
      await widget.repository.abandonWorkout(workout['id'] as String);
      if (mounted) _reload();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('暂时无法放弃训练，请恢复网络后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(top: false, child: ListView(padding: const EdgeInsets.fromLTRB(32, 32, 32, 48), children: [
    ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('今天', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      const SizedBox(height: 22),
      FutureBuilder<Map<String, dynamic>?>(future: _active, builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Card(child: Padding(padding: EdgeInsets.all(24), child: LinearProgressIndicator()));
        final workout = snapshot.data;
        if (workout == null) return _StartCard(onOpenPlans: widget.onOpenPlans);
        final name = (workout['plan_name'] as String?)?.trim();
        return Card(color: AppColors.surfaceRaised, child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name?.isNotEmpty == true ? name! : '正在进行的训练', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 4), const Text('继续完成，或明确放弃本次训练', style: TextStyle(color: AppColors.muted))])),
          TextButton(onPressed: () => _abandon(workout), child: const Text('放弃')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => _resume(workout), child: const Text('继续训练')),
        ])));
      }),
      if (!widget.repository.isOnline || widget.repository.pendingOperationCount > 0) ...[const SizedBox(height: 12), _SyncLine(repository: widget.repository)],
    ])),
  ]));
}

class _StartCard extends StatelessWidget {
  const _StartCard({this.onOpenPlans});
  final VoidCallback? onOpenPlans;
  @override
  Widget build(BuildContext context) => Card(color: AppColors.surfaceRaised, child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)), const SizedBox(width: 16), const Expanded(child: Text('选择一份训练计划开始', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))), FilledButton(onPressed: onOpenPlans, child: const Text('训练计划'))])));
}

class _SyncLine extends StatelessWidget {
  const _SyncLine({required this.repository});
  final TrainingRepository repository;
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(repository.isOnline ? Icons.cloud_upload_outlined : Icons.cloud_off_outlined, size: 16, color: repository.isOnline ? AppColors.muted : AppColors.warning),
    const SizedBox(width: 8),
    Expanded(child: Text(
      !repository.isSignedIn
          ? '未登录 · 数据仅在本机'
          : repository.pendingOperationCount > 0
          ? '${repository.pendingOperationCount} 条记录待同步'
          : '当前离线',
      style: const TextStyle(color: AppColors.muted, fontSize: 12))),
    if (repository.pendingOperationCount > 0) TextButton(onPressed: repository.isSyncing ? null : repository.flushQueue, child: const Text('同步')),
  ]);
}
