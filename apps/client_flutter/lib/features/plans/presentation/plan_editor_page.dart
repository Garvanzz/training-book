import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

/// 编辑一个“单次训练计划”。
class PlanEditorPage extends StatefulWidget {
  const PlanEditorPage({super.key, required this.repository, this.existingPlan});

  final TrainingRepository repository;
  final Map<String, dynamic>? existingPlan;

  @override
  State<PlanEditorPage> createState() => _PlanEditorPageState();
}

class _PlanEditorPageState extends State<PlanEditorPage> {
  final _planName = TextEditingController();
  final List<_StageDraft> _stages = [];
  late final Future<List<Map<String, dynamic>>> _exercises =
      widget.repository.loadExercises();
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.existingPlan != null;

  @override
  void initState() {
    super.initState();
    final plan = widget.existingPlan;
    if (plan == null) {
      _planName.text = '新的训练计划';
      _stages.add(_StageDraft(purpose: 'primary_strength', expanded: true));
      return;
    }
    _planName.text = (plan['name'] as String?) ?? '';
    for (final rawStage in _maps(plan['blocks'])) {
      final stage = _StageDraft(
        purpose: (rawStage['purpose'] as String?) ?? 'primary_strength',
      );
      for (final rawSlot in _maps(rawStage['slots'])) {
        final id = rawSlot['exercise_id'] as String?;
        if (id == null) continue;
        stage.exerciseIds.add(id);
        stage.prescriptions[id] = Map<String, dynamic>.from(
          (rawSlot['prescription'] as Map?)?.cast<String, dynamic>() ??
              _newPrescription(),
        );
        stage.alternatives[id] = _maps(rawSlot['alternatives']);
      }
      _stages.add(stage);
    }
    if (_stages.isEmpty) {
      _stages.add(_StageDraft(purpose: 'primary_strength', expanded: true));
    }
  }

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList()
      : const [];

  @override
  void dispose() {
    _planName.dispose();
    super.dispose();
  }

  Map<String, dynamic> _newPrescription() => <String, dynamic>{
        'prescription_type': 'free',
        'set_count': 1,
        'rep_min': null,
        'rep_max': null,
        'target_load_kg': null,
        'target_rpe': null,
        'target_rir': null,
        'rest_seconds': null,
        'tempo': null,
        'parameters': <String, dynamic>{},
        'progression_policy': <String, dynamic>{},
      };

  List<Map<String, dynamic>> _blocksPayload(List<Map<String, dynamic>> exercises) {
    final versions = <String, dynamic>{
      for (final exercise in exercises)
        if (exercise['id'] is String) exercise['id'] as String: exercise['version_no'],
    };
    final blocks = _stages
        .map(
          (stage) => <String, dynamic>{
            'purpose': stage.purpose,
            'custom_name': null,
            'config': <String, dynamic>{},
            'slots': stage.exerciseIds
                .map(
                  (id) => <String, dynamic>{
                    'exercise_id': id,
                    'exercise_version_no': versions[id],
                    'group_type': 'single',
                    'group_id': null,
                    'side_mode': 'combined',
                    'prescription': stage.prescriptions[id] ?? _newPrescription(),
                    'alternatives': (stage.alternatives[id] ?? const [])
                        .asMap()
                        .entries
                        .map(
                          (entry) => <String, dynamic>{
                            'exercise_id': entry.value['exercise_id'],
                            'rule_json': const <String, dynamic>{},
                            'priority': entry.key + 1,
                          },
                        )
                        .toList(),
                  },
                )
                .toList(),
          },
        )
        .toList();

    return blocks;
  }

  String? _validate() {
    if (_planName.text.trim().isEmpty) return '请为这次训练填写一个计划名称。';
    if (_stages.isEmpty) return '至少添加一个训练阶段。';
    for (final stage in _stages) {
      if (stage.exerciseIds.isEmpty) {
        return '“${_purposeName(stage.purpose)}”阶段还没有动作。';
      }
      for (final id in stage.exerciseIds) {
        final prescription = stage.prescriptions[id] ?? const <String, dynamic>{};
        final sets = prescription['set_count'];
        final min = prescription['rep_min'];
        final max = prescription['rep_max'];
        final rest = prescription['rest_seconds'];
        final rpe = prescription['target_rpe'];
        if (sets is! num || sets < 1 || (min != null && (min is! num || min < 0)) ||
            (max != null && (max is! num || (min is num && max < min))) ||
            (rest != null && (rest is! num || rest < 0)) ||
            (rpe != null && (rpe is! num || rpe < 0 || rpe > 10))) {
          return '请检查每个动作的组数、次数、休息和 RPE。';
        }
      }
    }
    return null;
  }

  Future<void> _save() async {
    final validation = _validate();
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final exercises = await _exercises;
      final blocks = _blocksPayload(exercises);
      if (_isEditing) {
        await widget.repository.replacePublishedPlan(
          planId: widget.existingPlan!['id'] as String,
          blocks: blocks,
        );
      } else {
        await widget.repository.createPlan(<String, dynamic>{
          'name': _planName.text.trim(),
          'goal': <String, dynamic>{'source': 'single_training_canvas'},
          'blocks': blocks,
        });
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (_) {
      if (mounted) setState(() => _error = '保存没有完成。请检查本机服务后重试。');
    } catch (_) {
      if (mounted) setState(() => _error = '保存没有完成，请稍后再试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addStage() => setState(() {
        _stages.add(_StageDraft(purpose: 'accessory', expanded: true));
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? '编辑训练计划' : '新建训练计划'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Visibility(
                visible: false,
                child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('保存计划'),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _exercises,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final exercises = snapshot.data ?? const <Map<String, dynamic>>[];
              return ListView(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: TextField(
                              controller: _planName,
                              decoration: const InputDecoration(
                                labelText: '计划名称',
                                hintText: '例如：下肢力量 / 上肢推 / 恢复训练',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        ReorderableListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          itemCount: _stages.length,
                          onReorderItem: (oldIndex, newIndex) => setState(() {
                            final stage = _stages.removeAt(oldIndex);
                            _stages.insert(newIndex, stage);
                          }),
                          itemBuilder: (context, index) => Padding(
                            key: ValueKey(_stages[index]),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _StageCanvas(
                              stage: _stages[index],
                              stageIndex: index,
                              exercises: exercises,
                              newPrescription: _newPrescription,
                              canRemove: _stages.length > 1,
                              onChanged: () => setState(() {}),
                              onRemove: () => setState(() => _stages.removeAt(index)),
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _addStage,
                          icon: const Icon(Icons.add),
                          label: const Text('添加训练阶段'),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 18),
                          _InlineError(message: _error!),
                        ],
                        const SizedBox(height: 32),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.check),
                            label: const Text('保存本次训练计划'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
}

class _StageDraft {
  _StageDraft({required this.purpose, this.expanded = false});

  String purpose;
  bool expanded;
  final List<String> exerciseIds = [];
  final Map<String, Map<String, dynamic>> prescriptions = {};
  /// exerciseId -> [{exercise_id, exercise_name_zh}] in priority order.
  final Map<String, List<Map<String, dynamic>>> alternatives = {};
}

class _StageCanvas extends StatelessWidget {
  const _StageCanvas({
    required this.stage,
    required this.stageIndex,
    required this.exercises,
    required this.newPrescription,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final _StageDraft stage;
  final int stageIndex;
  final List<Map<String, dynamic>> exercises;
  final Map<String, dynamic> Function() newPrescription;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final actionCount = stage.exerciseIds.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () {
              stage.expanded = !stage.expanded;
              onChanged();
            },
            leading: Row(mainAxisSize: MainAxisSize.min, children: [ReorderableDragStartListener(index: stageIndex, child: const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.drag_indicator, color: AppColors.muted))), _StageNumber(number: stageIndex + 1)]),
            title: Text(_purposeName(stage.purpose),
                style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(actionCount == 0 ? '尚未添加动作' : '$actionCount 个动作'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canRemove)
                  IconButton(
                    tooltip: '删除阶段',
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
                Icon(stage.expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
          if (stage.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: stage.purpose,
                    decoration: const InputDecoration(labelText: '训练阶段'),
                    items: _purposeItems,
                    onChanged: (value) {
                      if (value == null) return;
                      stage.purpose = value;
                      onChanged();
                    },
                  ),
                  const SizedBox(height: 18),
                  if (stage.exerciseIds.isNotEmpty)
                    for (final id in stage.exerciseIds) ...[
                      _ExercisePrescriptionCard(
                        name: _exerciseName(exercises, id),
                        prescription: stage.prescriptions[id] ?? newPrescription(),
                        alternativeCount: (stage.alternatives[id] ?? const []).length,
                        onEdit: () => _editPrescription(context, id),
                        onEditAlternatives: () => _editAlternatives(context, id),
                        onRemove: () {
                          stage.exerciseIds.remove(id);
                          stage.prescriptions.remove(id);
                          stage.alternatives.remove(id);
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: exercises.isEmpty ? null : () => _pickExercise(context),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('从动作库添加动作'),
                  ),
                  if (exercises.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('动作库还没有已发布动作。',
                          style: TextStyle(color: AppColors.warning)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickExercise(BuildContext context) async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _ExercisePicker(
        exercises: exercises.where((item) => !stage.exerciseIds.contains(item['id'])).toList(),
      ),
    );
    if (id == null) return;
    stage.exerciseIds.add(id);
    stage.prescriptions[id] = newPrescription();
    onChanged();
  }

  Future<void> _editPrescription(BuildContext context, String id) async {
    final changed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PrescriptionDialog(
        initial: stage.prescriptions[id] ?? newPrescription(),
      ),
    );
    if (changed == null) return;
    stage.prescriptions[id] = changed;
    onChanged();
  }

  Future<void> _editAlternatives(BuildContext context, String id) async {
    final changed = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => _AlternativesDialog(
        exercises: exercises,
        initial: stage.alternatives[id] ?? const [],
        excludeId: id,
      ),
    );
    if (changed == null) return;
    stage.alternatives[id] = changed;
    onChanged();
  }
}

class _StageNumber extends StatelessWidget {
  const _StageNumber({required this.number});
  final int number;

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceInteractive,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text('$number', style: const TextStyle(fontWeight: FontWeight.w800)),
      );
}

class _ExercisePrescriptionCard extends StatelessWidget {
  const _ExercisePrescriptionCard({
    required this.name,
    required this.prescription,
    required this.alternativeCount,
    required this.onEdit,
    required this.onEditAlternatives,
    required this.onRemove,
  });

  final String name;
  final Map<String, dynamic> prescription;
  final int alternativeCount;
  final VoidCallback onEdit;
  final VoidCallback onEditAlternatives;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 5),
                  Text(_prescriptionLabel(prescription),
                      style: const TextStyle(color: AppColors.muted)),
                ],
              ),
            ),
            OutlinedButton(onPressed: onEdit, child: const Text('训练设置')),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: onEditAlternatives,
              child: Text(alternativeCount == 0 ? '替代动作' : '替代动作（$alternativeCount）'),
            ),
            IconButton(tooltip: '移除动作', onPressed: onRemove, icon: const Icon(Icons.close)),
          ],
        ),
      );
}

class _ExercisePicker extends StatelessWidget {
  const _ExercisePicker({required this.exercises});
  final List<Map<String, dynamic>> exercises;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('选择动作'),
        content: SizedBox(
          width: 520,
          child: exercises.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('没有可添加的已发布动作。'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: exercises.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final exercise = exercises[index];
                    return ListTile(
                      title: Text((exercise['name_zh'] as String?) ?? '未命名动作'),
                      trailing: const Icon(Icons.add),
                      onTap: () => Navigator.of(context).pop(exercise['id'] as String),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
      );
}

class _AlternativesDialog extends StatefulWidget {
  const _AlternativesDialog({
    required this.exercises,
    required this.initial,
    required this.excludeId,
  });

  final List<Map<String, dynamic>> exercises;
  final List<Map<String, dynamic>> initial;
  final String excludeId;

  @override
  State<_AlternativesDialog> createState() => _AlternativesDialogState();
}

class _AlternativesDialogState extends State<_AlternativesDialog> {
  late final List<Map<String, dynamic>> _selected = widget.initial
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  Future<void> _add() async {
    final available = widget.exercises
        .where((exercise) =>
            exercise['id'] != widget.excludeId &&
            !_selected.any((selected) => selected['exercise_id'] == exercise['id']))
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _ExercisePicker(exercises: available),
    );
    if (id == null) return;
    final exercise = widget.exercises.firstWhere((item) => item['id'] == id);
    setState(() {
      _selected.add({'exercise_id': id, 'exercise_name_zh': exercise['name_zh']});
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('替代动作'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '器械被占用或身体不适时，可改用同模式的替代动作。',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (_selected.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('还没有配置替代动作。'),
            )
          else
            for (final item in _selected)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.swap_horiz, color: AppColors.accent, size: 20),
                title: Text(item['exercise_name_zh']?.toString() ?? '动作'),
                trailing: IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _selected.remove(item)),
                ),
              ),
          TextButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('添加替代动作'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _selected),
        child: const Text('保存'),
      ),
    ],
  );
}

class _PrescriptionDialog extends StatefulWidget {
  const _PrescriptionDialog({required this.initial});
  final Map<String, dynamic> initial;

  @override
  State<_PrescriptionDialog> createState() => _PrescriptionDialogState();
}

class _PrescriptionDialogState extends State<_PrescriptionDialog> {
  late final _sets = TextEditingController(text: '${widget.initial['set_count'] ?? 1}');
  late final _min = TextEditingController(text: widget.initial['rep_min']?.toString() ?? '');
  late final _max = TextEditingController(text: widget.initial['rep_max']?.toString() ?? '');
  late final _load = TextEditingController(
      text: widget.initial['target_load_kg'] == null ? '' : '${widget.initial['target_load_kg']}');
  late final _rest = TextEditingController(text: widget.initial['rest_seconds']?.toString() ?? '');
  late final _rpe = TextEditingController(text: widget.initial['target_rpe']?.toString() ?? '');
  String? _error;

  @override
  void dispose() {
    _sets.dispose();
    _min.dispose();
    _max.dispose();
    _load.dispose();
    _rest.dispose();
    _rpe.dispose();
    super.dispose();
  }

  int? _integer(TextEditingController controller) => int.tryParse(controller.text.trim());
  double? _decimal(TextEditingController controller) => double.tryParse(controller.text.trim());

  void _save() {
    final sets = _integer(_sets);
    final min = _min.text.trim().isEmpty ? null : _integer(_min);
    final max = _max.text.trim().isEmpty ? null : _integer(_max);
    final rest = _rest.text.trim().isEmpty ? null : _integer(_rest);
    final rpe = _rpe.text.trim().isEmpty ? null : _decimal(_rpe);
    final load = _load.text.trim().isEmpty ? null : _decimal(_load);
    if (sets == null || sets < 1 || (min != null && min < 0) ||
        (max != null && (max < 0 || (min != null && max < min))) ||
        (rest != null && rest < 0) || (rpe != null && (rpe < 0 || rpe > 10)) ||
        (_load.text.trim().isNotEmpty && (load == null || load < 0))) {
      setState(() => _error = '请检查数值：组数至少为 1，次数和休息不能为负数，RPE 为 0–10。');
      return;
    }
    Navigator.of(context).pop(<String, dynamic>{
      ...widget.initial,
      'set_count': sets,
      'rep_min': min,
      'rep_max': max,
      'target_load_kg': load,
      'rest_seconds': rest,
      'target_rpe': rpe,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('动作训练设置'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这些参数只作用于当前动作。重量可以留空。',
                  style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _NumberInput(controller: _sets, label: '组数'),
                  _NumberInput(controller: _min, label: '最少次数'),
                  _NumberInput(controller: _max, label: '最多次数'),
                  _NumberInput(controller: _load, label: '重量（kg）', hint: '可留空', alwaysFloatLabel: true, decimal: true),
                  _NumberInput(controller: _rest, label: '组间休息（秒）'),
                  _NumberInput(controller: _rpe, label: '目标 RPE（0–10）', decimal: true),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _InlineError(message: _error!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: _save, child: const Text('应用设置')),
        ],
      );
}

class _NumberInput extends StatelessWidget {
  const _NumberInput({required this.controller, required this.label, this.hint, this.alwaysFloatLabel = false, this.decimal = false});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool alwaysFloatLabel;
  final bool decimal;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: TextField(
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            floatingLabelBehavior: alwaysFloatLabel ? FloatingLabelBehavior.always : FloatingLabelBehavior.auto,
          ),
        ),
      );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.danger.withValues(alpha: .5)),
        ),
        child: Text(message, style: const TextStyle(color: AppColors.danger)),
      );
}

String _exerciseName(List<Map<String, dynamic>> exercises, String id) {
  final exercise = exercises.where((item) => item['id'] == id).firstOrNull;
  return (exercise?['name_zh'] as String?) ?? '未命名动作';
}

String _prescriptionLabel(Map<String, dynamic> prescription) {
  final load = prescription['target_load_kg'];
  final weight = load == null ? '不设重量' : '$load kg';
  return '${prescription['set_count'] ?? '-'} 组 × ${prescription['rep_min'] ?? '-'}–${prescription['rep_max'] ?? '-'} 次 · $weight · RPE ${prescription['target_rpe'] ?? '-'} · 休息 ${prescription['rest_seconds'] ?? '-'} 秒';
}

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

const _purposeItems = <DropdownMenuItem<String>>[
  DropdownMenuItem(value: 'general_warmup', child: Text('热身')),
  DropdownMenuItem(value: 'mobility', child: Text('活动度')),
  DropdownMenuItem(value: 'activation_control', child: Text('激活与控制')),
  DropdownMenuItem(value: 'movement_prep', child: Text('动作准备')),
  DropdownMenuItem(value: 'power_skill', child: Text('爆发 / 技术')),
  DropdownMenuItem(value: 'primary_strength', child: Text('力量训练')),
  DropdownMenuItem(value: 'accessory', child: Text('辅助训练')),
  DropdownMenuItem(value: 'local_endurance', child: Text('局部耐力')),
  DropdownMenuItem(value: 'conditioning', child: Text('有氧 / 体能')),
  DropdownMenuItem(value: 'cooldown_recovery', child: Text('冷身与恢复')),
];
