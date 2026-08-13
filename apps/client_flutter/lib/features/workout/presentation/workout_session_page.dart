import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../library/presentation/exercise_detail_page.dart';
import 'workout_summary_page.dart';

class WorkoutSessionPage extends StatefulWidget {
  const WorkoutSessionPage({super.key, required this.repository, required this.workout});

  final TrainingRepository repository;
  final Map<String, dynamic> workout;

  @override
  State<WorkoutSessionPage> createState() => _WorkoutSessionPageState();
}

class _WorkoutSessionPageState extends State<WorkoutSessionPage> {
  final Map<String, Map<int, _SetEntry>> _sets = {};
  final Set<String> _saving = {};
  final Map<String, double> _rpes = {};
  int _currentItemIndex = 0;
  bool _isCompleting = false;

  List<Map<String, dynamic>> get _items =>
      (widget.workout['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
  Map<String, dynamic> get _item => _items[_currentItemIndex];
  Map<String, dynamic> get _prescription =>
      Map<String, dynamic>.from(_item['prescription_snapshot'] as Map? ?? const {});
  String get _itemId => _item['id'] as String;
  String get _sessionId => widget.workout['id'] as String;

  int _setCount(Map<String, dynamic> item) {
    final prescription = item['prescription_snapshot'] as Map? ?? const {};
    return ((prescription['set_count'] as num?)?.toInt() ?? 1).clamp(1, 99);
  }

  String _itemName(Map<String, dynamic> item) {
    final snapshot = item['exercise_snapshot'] as Map? ?? const {};
    return snapshot['name_zh'] as String? ?? '训练动作';
  }

  String _saveKey(String itemId, int set) => '$itemId:$set';

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList()
      : const [];

  /// Alternatives come from the offline-built item or, for server sessions,
  /// from the cached plan detail by matching the source slot.
  Future<List<Map<String, dynamic>>> _alternativesFor(Map<String, dynamic> item) async {
    final direct = item['alternatives'];
    if (direct is List && direct.isNotEmpty) return _maps(direct);
    final sourceSlotId = item['source_slot_id']?.toString();
    final planId = widget.workout['source_plan_id']?.toString();
    if (sourceSlotId == null || planId == null) return const [];
    final plan = await widget.repository.cachedPlanDetail(planId);
    if (plan == null) return const [];
    for (final block in _maps(plan['blocks'])) {
      for (final slot in _maps(block['slots'])) {
        if (slot['id']?.toString() == sourceSlotId) {
          return _maps(slot['alternatives']);
        }
      }
    }
    return const [];
  }

  Future<void> _openAlternatives() async {
    final alternatives = await _alternativesFor(_item);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
          shrinkWrap: true,
          children: [
            const Text('替代动作', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
              '器械被占用或身体不适时可临时替换；本次记录仍归属原动作，计划不受影响。',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (alternatives.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('这份计划没有为该动作配置替代动作。', style: TextStyle(color: AppColors.muted)),
              )
            else
              for (final alternative in alternatives)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.swap_horiz, color: AppColors.accent),
                  title: Text(alternative['exercise_name_zh']?.toString() ?? '动作'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _replaceWith(alternative);
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// "This session only" replacement: swap the display snapshot, keep the
  /// original immutable workout item for records.
  void _replaceWith(Map<String, dynamic> alternative) {
    final replacementName = alternative['exercise_name_zh']?.toString();
    setState(() {
      _item['exercise_snapshot'] = {
        ...(_item['exercise_snapshot'] as Map? ?? const {}),
        if (replacementName != null && replacementName.isNotEmpty)
          'name_zh': replacementName,
      };
    });
    if (replacementName != null && replacementName.isNotEmpty) {
      _showMessage('已临时替换为 $replacementName');
    }
  }
  Future<void> _openExerciseDetail() async {
    final exerciseId = _item['exercise_id'] as String?;
    if (exerciseId == null || !mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => ExerciseDetailPage(repository: widget.repository, exerciseId: exerciseId)));
  }
  bool _hasLoad(Map<String, dynamic> prescription) => prescription['target_load_kg'] is num;
  bool _hasReps(Map<String, dynamic> prescription) =>
      prescription['rep_min'] is num || prescription['rep_max'] is num;
  bool _hasRpe(Map<String, dynamic> prescription) => prescription['target_rpe'] is num;

  _SetEntry _setFor(String itemId, int index, Map<String, dynamic> prescription) {
    final local = _sets[itemId]?[index];
    if (local != null) return local;
    final item = _items.firstWhere((candidate) => candidate['id'] == itemId, orElse: () => const {});
    final logs = (item['set_logs'] as List<dynamic>? ?? const []).whereType<Map>();
    final logged = logs.cast<Map>().where((log) => (log['set_number'] as num?)?.toInt() == index && log['status'] == 'completed').firstOrNull;
    return _SetEntry(
      (logged?['load_kg'] as num?)?.toDouble() ?? (prescription['target_load_kg'] as num?)?.toDouble(),
      (logged?['reps'] as num?)?.toInt() ?? ((prescription['rep_max'] ?? prescription['rep_min']) as num?)?.toInt(),
      logged != null,
    );
  }

  void _setEntry(String itemId, int index, _SetEntry value) {
    setState(() => _sets.putIfAbsent(itemId, () => {})[index] = value);
  }

  double _rpeFor(String itemId) {
    final target = _prescription['target_rpe'] as num?;
    return _rpes[itemId] ?? target?.toDouble() ?? 8;
  }

  int get _completedSets => _items.fold<int>(0, (sum, item) {
        final id = item['id'] as String;
        final prescription = Map<String, dynamic>.from(item['prescription_snapshot'] as Map? ?? const {});
        return sum +
            List.generate(_setCount(item), (i) => _setFor(id, i + 1, prescription).done)
                .where((done) => done)
                .length;
      });
  int get _totalSets => _items.fold<int>(0, (sum, item) => sum + _setCount(item));

  void _showMessage(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 92),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          duration: const Duration(seconds: 1),
          backgroundColor: isError ? AppColors.danger : null,
          content: Text(text),
        ),
      );
  }

  Future<void> _saveSet(int index) async {
    final entry = _setFor(_itemId, index, _prescription);
    final key = _saveKey(_itemId, index);
    setState(() => _saving.add(key));
    try {
      await widget.repository.saveSet(
        sessionId: _sessionId,
        itemId: _itemId,
        setNumber: index,
        loadKg: _hasLoad(_prescription) ? entry.weight : null,
        reps: _hasReps(_prescription) ? entry.reps : null,
        rpe: _hasRpe(_prescription) ? _rpeFor(_itemId) : null,
      );
      _setEntry(_itemId, index, entry.copyWith(done: true));
      _showMessage(widget.repository.isOnline ? '第 $index 组已保存' : '第 $index 组已离线保存，联网后会自动同步');
    } on ApiException catch (error) {
      _showMessage(error.message.isEmpty ? '保存失败，请稍后重试' : error.message, isError: true);
    } catch (_) {
      _showMessage('保存失败，请检查本机服务或网络后重试', isError: true);
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  Future<void> _complete() async {
    if (_completedSets < _totalSets) {
      _showMessage('还有 ${_totalSets - _completedSets} 组未完成。请完成每一组后再结束训练。', isError: true);
      return;
    }
    setState(() => _isCompleting = true);
    try {
      await widget.repository.completeWorkout(_sessionId);
      if (!mounted) return;
      final suggestions = await _collectSuggestions();
      if (!mounted) return;
      // Build the summary from in-memory set state so the page shows exactly
      // what was recorded, including sets saved offline this session.
      final summaryWorkout = <String, dynamic>{
        ...widget.workout,
        'items': _items.map((item) {
          final prescription =
              Map<String, dynamic>.from(item['prescription_snapshot'] as Map? ?? const {});
          final itemId = item['id'] as String;
          final logs = <Map<String, dynamic>>[];
          for (var index = 1; index <= _setCount(item); index++) {
            final entry = _setFor(itemId, index, prescription);
            if (!entry.done) continue;
            logs.add({
              'set_number': index,
              'load_kg': entry.weight,
              'reps': entry.reps,
              'rpe': _rpeFor(itemId),
              'status': 'completed',
            });
          }
          return {...item, 'set_logs': logs};
        }).toList(),
      };
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WorkoutSummaryPage(
            repository: widget.repository,
            workout: summaryWorkout,
            endedAt: DateTime.now(),
            suggestions: suggestions,
          ),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      _showMessage(error.message.isEmpty ? '无法完成训练，请稍后重试' : error.message, isError: true);
    } catch (_) {
      _showMessage('无法完成训练，请检查网络后重试', isError: true);
    } finally {
      if (mounted) setState(() => _isCompleting = false);
    }
  }

  /// Generates the next-load suggestion for every item that had a target
  /// weight.  Offline completions skip this silently: the suggestion endpoint
  /// needs connectivity and the sets are already queued for sync.
  Future<List<Map<String, dynamic>>> _collectSuggestions() async {
    final results = <Map<String, dynamic>>[];
    for (final item in _items) {
      final prescription = item['prescription_snapshot'] as Map? ?? const {};
      if (prescription['target_load_kg'] is! num) continue;
      try {
        final suggestion = await widget.repository.generateProgressionSuggestion(
          item['id'] as String,
        );
        results.add({...suggestion, 'name_zh': _itemName(item)});
      } catch (_) {
        // A failed suggestion must never block finishing the workout.
      }
    }
    return results;
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const Scaffold(body: Center(child: Text('这次训练没有可记录的动作。')));
    }
    final hasLoad = _hasLoad(_prescription);
    final hasReps = _hasReps(_prescription);
    final hasRpe = _hasRpe(_prescription);
    return Scaffold(
      appBar: AppBar(title: const Text('进行中的训练')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth >= 840 ? 860 : double.infinity),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 112),
                children: [
                  _ConnectionBanner(repository: widget.repository),
                  const SizedBox(height: 18),
                  Row(children: [
                    Text('$_completedSets / $_totalSets 组已完成', style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _totalSets == 0 ? 0 : _completedSets / _totalSets,
                          minHeight: 7,
                          backgroundColor: AppColors.surfaceInteractive,
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        ChoiceChip(
                          label: Text('${i + 1}. ${_itemName(_items[i])}'),
                          selected: i == _currentItemIndex,
                          onSelected: (_) => setState(() => _currentItemIndex = i),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  InkWell(
                    onTap: _item['exercise_id'] is String ? _openExerciseDetail : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(children: [
                      Expanded(child: Text(_itemName(_item), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800))),
                      IconButton(
                        tooltip: '替代动作',
                        icon: const Icon(Icons.swap_horiz),
                        onPressed: _openAlternatives,
                      ),
                      if (_item['exercise_id'] is String) const Icon(Icons.info_outline, color: AppColors.muted),
                    ]),
                  ),
                  if (_prescriptionLabel(_prescription).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_prescriptionLabel(_prescription), style: const TextStyle(color: AppColors.muted)),
                  ],
                  const SizedBox(height: 18),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: [
                          for (var index = 1; index <= _setCount(_item); index++) ...[
                            _SetRow(
                              number: index,
                              entry: _setFor(_itemId, index, _prescription),
                              showLoad: hasLoad,
                              showReps: hasReps,
                              saving: _saving.contains(_saveKey(_itemId, index)),
                              onChanged: (entry) => _setEntry(_itemId, index, entry),
                              onSave: () => _saveSet(index),
                            ),
                            if (index < _setCount(_item)) const Divider(height: 26),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (hasRpe) ...[
                    const SizedBox(height: 22),
                    const Text('主观用力程度', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    Text(
                      'RPE ${_rpeFor(_itemId).toStringAsFixed(0)}：还可以完成 ${(10 - _rpeFor(_itemId)).round()} 次左右。',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    Slider(
                      value: _rpeFor(_itemId),
                      min: 5,
                      max: 10,
                      divisions: 5,
                      label: 'RPE ${_rpeFor(_itemId).toStringAsFixed(0)}',
                      onChanged: (value) => setState(() => _rpes[_itemId] = value),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      bottomSheet: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isCompleting ? null : _complete,
            icon: _isCompleting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_circle_outline),
            label: const Text('完成训练'),
          ),
        ),
      ),
    );
  }

  String _prescriptionLabel(Map<String, dynamic> prescription) {
    final parts = <String>['${prescription['set_count'] ?? 1} 组'];
    final min = prescription['rep_min'];
    final max = prescription['rep_max'];
    if (min is num && max is num) {
      parts.add(min == max ? '${min.toInt()} 次' : '${min.toInt()}–${max.toInt()} 次');
    } else if (max is num || min is num) {
      final value = max is num ? max : min as num;
      parts.add('${value.toInt()} 次');
    }
    final load = prescription['target_load_kg'];
    if (load is num) parts.add('${load.toStringAsFixed(1)} kg');
    return parts.join(' · ');
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.repository});
  final TrainingRepository repository;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: Icon(
            repository.isOnline ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: repository.isOnline ? AppColors.accent : AppColors.warning,
          ),
          title: Text(repository.isOnline ? '训练记录会自动保存' : '离线记录会保存在本机'),
          subtitle: repository.pendingOperationCount == 0 ? null : Text('${repository.pendingOperationCount} 条记录等待同步'),
        ),
      );
}

class _SetRow extends StatelessWidget {
  const _SetRow({
    required this.number,
    required this.entry,
    required this.showLoad,
    required this.showReps,
    required this.saving,
    required this.onChanged,
    required this.onSave,
  });

  final int number;
  final _SetEntry entry;
  final bool showLoad;
  final bool showReps;
  final bool saving;
  final ValueChanged<_SetEntry> onChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final isCheckOnly = !showLoad && !showReps;
    return Row(
      children: [
        SizedBox(width: 52, child: Text('第 $number 组', style: const TextStyle(fontWeight: FontWeight.w700))),
        if (showLoad)
          _MeasureButton(
            label: '${entry.weight?.toStringAsFixed(1) ?? '—'} kg',
            onDecrement: () => onChanged(entry.copyWith(weight: ((entry.weight ?? 0) - 2.5).clamp(0, double.infinity).toDouble())),
            onIncrement: () => onChanged(entry.copyWith(weight: (entry.weight ?? 0) + 2.5)),
          ),
        if (showLoad && showReps) const SizedBox(width: 8),
        if (showReps)
          _MeasureButton(
            label: '${entry.reps ?? '—'} 次',
            onDecrement: () => onChanged(entry.copyWith(reps: (entry.reps ?? 0) > 0 ? entry.reps! - 1 : 0)),
            onIncrement: () => onChanged(entry.copyWith(reps: (entry.reps ?? 0) + 1)),
          ),
        if (isCheckOnly) const Expanded(child: Text('完成即可', style: TextStyle(color: AppColors.muted))),
        const Spacer(),
        IconButton(
          tooltip: saving ? '正在保存' : entry.done ? '已完成' : '完成本组',
          onPressed: saving ? null : onSave,
          icon: saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(entry.done ? Icons.check_circle : Icons.check_circle_outline, color: entry.done ? AppColors.accent : null),
        ),
      ],
    );
  }
}

class _MeasureButton extends StatelessWidget {
  const _MeasureButton({required this.label, required this.onDecrement, required this.onIncrement});
  final String label;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: '减少', onPressed: onDecrement, icon: const Icon(Icons.remove)),
          SizedBox(width: 70, child: Text(label, textAlign: TextAlign.center)),
          IconButton(tooltip: '增加', onPressed: onIncrement, icon: const Icon(Icons.add)),
        ],
      );
}

class _SetEntry {
  const _SetEntry(this.weight, this.reps, this.done);
  final double? weight;
  final int? reps;
  final bool done;

  _SetEntry copyWith({double? weight, int? reps, bool? done}) =>
      _SetEntry(weight ?? this.weight, reps ?? this.reps, done ?? this.done);
}

