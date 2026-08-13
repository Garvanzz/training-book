import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../library/presentation/exercise_detail_page.dart';
import '../../workout/presentation/workout_session_page.dart';
import 'plan_editor_page.dart';

class PlansPage extends StatefulWidget {
  const PlansPage({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  late Future<List<Map<String, dynamic>>> _plans = widget.repository.loadPlans();

  void _reload() => setState(() => _plans = widget.repository.loadPlans());

  Future<void> _createPlan() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => PlanEditorPage(repository: widget.repository)),
    );
    if (saved == true) _reload();
  }

  Future<void> _deletePlan(Map<String, dynamic> plan) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这份训练计划？'),
        content: const Text('删除后不能再开始它；已完成的训练历史不会受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await widget.repository.deletePlan(plan['id'] as String);
      if (mounted) _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂时无法删除，请稍后重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _plans,
          builder: (context, snapshot) => RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('训练计划', style: Theme.of(context).textTheme.displaySmall),
                        ],
                      ),
                    ),
                    IconButton(tooltip: '刷新计划', onPressed: _reload, icon: const Icon(Icons.refresh)),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _createPlan,
                      icon: const Icon(Icons.add),
                      label: const Text('新建训练计划'),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if ((snapshot.data ?? []).isEmpty)
                  _EmptyPlans(isSignedOut: !widget.repository.isSignedIn)
                else
                  for (final plan in snapshot.data!) ...[
                    _PlanCard(
                      plan: plan,
                      onOpen: () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => PlanDetailPage(
                              repository: widget.repository,
                              planId: plan['id'] as String,
                            ),
                          ),
                        );
                        _reload();
                      },
                      onDelete: () => _deletePlan(plan),
                    ),
                    const SizedBox(height: 12),
                  ],
              ],
            ),
          ),
        ),
      );
}

class _EmptyPlans extends StatelessWidget {
  const _EmptyPlans({required this.isSignedOut});
  final bool isSignedOut;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isSignedOut ? Icons.lock_outline : Icons.playlist_add_outlined,
                size: 32,
                color: AppColors.accent,
              ),
              const SizedBox(height: 12),
              Text(
                isSignedOut ? '登录后可恢复计划' : '还没有训练计划',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                isSignedOut
                    ? '当前未登录。登录后会自动显示并同步账号下的计划。'
                    : '点右上角“新建训练计划”开始',
                style: const TextStyle(color: AppColors.muted),
              ),
            ],
          ),
        ),
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.onOpen, required this.onDelete});
  final Map<String, dynamic> plan;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final stageCount = (plan['block_count'] as num?)?.toInt() ??
        _countStages(plan);
    final actionCount = (plan['exercise_slot_count'] as num?)?.toInt() ?? _countActions(plan);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceInteractive,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.fitness_center, color: AppColors.accent),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((plan['name'] as String?) ?? '未命名训练',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 5),
                    Text('$stageCount 个阶段 · $actionCount 个动作',
                        style: const TextStyle(color: AppColors.muted)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除计划')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlanDetailPage extends StatefulWidget {
  const PlanDetailPage({super.key, required this.repository, required this.planId});
  final TrainingRepository repository;
  final String planId;

  @override
  State<PlanDetailPage> createState() => _PlanDetailPageState();
}

class _PlanDetailPageState extends State<PlanDetailPage> {
  late Future<Map<String, dynamic>?> _plan = widget.repository.loadPlanDetail(widget.planId);
  bool _starting = false;

  Future<void> _editPlan(Map<String, dynamic> plan) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PlanEditorPage(repository: widget.repository, existingPlan: plan),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _plan = widget.repository.loadPlanDetail(widget.planId));
    }
  }

  Future<void> _startWorkout(Map<String, dynamic> plan) async {
    final planId = plan['id'] as String?;
    if (planId == null) {
      _showMessage('此计划还没有可开始的训练内容。');
      return;
    }
    setState(() => _starting = true);
    try {
      final active = await widget.repository.loadActiveWorkout();
      if (active != null && mounted) {
        final choice = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: const Text('已有未完成训练'),
            content: Text('当前有一场${(active['plan_name'] as String?)?.trim().isNotEmpty == true ? '“${(active['plan_name'] as String).trim()}”' : ''}尚未完成，请先选择如何处理。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
              OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('放弃并开始新的')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续当前训练')),
            ],
          ),
        );
        if (choice == null) return;
        if (choice) {
          if (!mounted) return;
          await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => WorkoutSessionPage(repository: widget.repository, workout: active)));
          return;
        }
        await widget.repository.abandonWorkout(active['id'] as String);
      }
      final workout = await widget.repository.startWorkout(planId);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WorkoutSessionPage(repository: widget.repository, workout: workout),
        ),
      );
    } on ApiException catch (_) {
      if (mounted) _showMessage('无法开始训练。请检查本机服务和网络状态。');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: FutureBuilder<Map<String, dynamic>?>(
          future: _plan,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final plan = snapshot.data;
            if (plan == null) {
              return const Center(child: Text('无法读取本地训练计划。'));
            }
            final stages = _blocksFor(plan);
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 112),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text((plan['name'] as String?) ?? '未命名训练', style: Theme.of(context).textTheme.headlineSmall),
                                const SizedBox(height: 5),
                                Text('${stages.length} 个阶段 · ${_actionCount(stages)} 个动作', style: const TextStyle(color: AppColors.muted)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '编辑计划',
                            onPressed: widget.repository.isOnline ? () => _editPlan(plan) : null,
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.icon(
                            onPressed: widget.repository.isOnline && !_starting
                                ? () => _startWorkout(plan)
                                : null,
                            icon: _starting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow),
                            label: const Text('开始本次训练'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      if (stages.isEmpty)
                        const _PlanContentEmpty()
                      else
                        for (var index = 0; index < stages.length; index++) ...[
                          _StageOverview(stage: stages[index], number: index + 1, repository: widget.repository),
                          const SizedBox(height: 12),
                        ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );
}

class _PlanContentEmpty extends StatelessWidget {
  const _PlanContentEmpty();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('这个计划还没有训练阶段。编辑计划后添加动作。'),
        ),
      );
}

class _StageOverview extends StatelessWidget {
  const _StageOverview({required this.stage, required this.number, required this.repository});
  final Map<String, dynamic> stage;
  final int number;
  final TrainingRepository repository;

  @override
  Widget build(BuildContext context) {
    final slots = _maps(stage['slots']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PlanStageNumber(number: number),
                const SizedBox(width: 10),
                Text(_purposeName((stage['purpose'] as String?) ?? ''),
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 14),
            for (final slot in slots) ...[
              _SlotOverview(slot: slot, repository: repository),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanStageNumber extends StatelessWidget {
  const _PlanStageNumber({required this.number});
  final int number;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceInteractive,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('$number', style: const TextStyle(fontWeight: FontWeight.w800)),
      );
}

class _SlotOverview extends StatelessWidget {
  const _SlotOverview({required this.slot, required this.repository});
  final Map<String, dynamic> slot;
  final TrainingRepository repository;

  @override
  Widget build(BuildContext context) {
    final exercise = (slot['exercise_snapshot'] as Map?)?.cast<String, dynamic>();
    final prescription = (slot['prescription'] as Map?)?.cast<String, dynamic>() ?? const {};
    final name = (slot['exercise_name_zh'] as String?) ??
        (exercise?['name_zh'] as String?) ??
        '训练动作';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              final exerciseId = slot['exercise_id'] as String?;
              if (exerciseId == null) return;
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExerciseDetailPage(repository: repository, exerciseId: exerciseId)));
            },
            child: Row(children: [Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700))), if (slot['exercise_id'] != null) const Icon(Icons.open_in_new, size: 16, color: AppColors.muted)]),
          ),
          const SizedBox(height: 4),
          Text(_prescriptionLine(prescription),
              style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        ],
      ),
    );
  }
}

List<Map<String, dynamic>> _blocksFor(Map<String, dynamic> plan) => _maps(plan['blocks']);

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList()
    : const [];

int _actionCount(List<Map<String, dynamic>> stages) =>
    stages.fold(0, (count, stage) => count + _maps(stage['slots']).length);

int _countStages(Map<String, dynamic> plan) => _blocksFor(plan).length;

int _countActions(Map<String, dynamic> plan) => _actionCount(_blocksFor(plan));

String _purposeName(String purpose) => switch (purpose) {
      'general_warmup' => '热身',
      'mobility' => '活动度',
      'activation_control' => '激活与控制',
      'movement_prep' => '动作准备',
      'power_skill' => '爆发 / 技术',
      'primary_strength' => '力量训练',
      'accessory' => '辅助训练',
      'local_endurance' => '局部耐力',
      'conditioning' => '有氧 / 体能',
      'cooldown_recovery' => '冷身与恢复',
      _ => '训练阶段',
    };

String _prescriptionLine(Map<String, dynamic> value) {
  final weight = value['target_load_kg'];
  final rest = value['rest_seconds'];
  return '${value['set_count'] ?? '-'} 组 × ${value['rep_min'] ?? '-'}–${value['rep_max'] ?? '-'} 次${weight == null ? '' : ' · $weight kg'} · RPE ${value['target_rpe'] ?? '-'}${rest == null ? '' : ' · $rest 秒'}';
}
