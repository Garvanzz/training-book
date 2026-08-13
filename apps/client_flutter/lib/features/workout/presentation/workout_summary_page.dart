import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

/// 完成训练后的总结页:开始/结束时间、总时长、动作组明细与下次重量建议。
class WorkoutSummaryPage extends StatefulWidget {
  const WorkoutSummaryPage({
    super.key,
    required this.repository,
    required this.workout,
    required this.endedAt,
    required this.suggestions,
  });

  final TrainingRepository repository;
  final Map<String, dynamic> workout;
  final DateTime endedAt;
  final List<Map<String, dynamic>> suggestions;

  @override
  State<WorkoutSummaryPage> createState() => _WorkoutSummaryPageState();
}

class _WorkoutSummaryPageState extends State<WorkoutSummaryPage> {
  List<Map<String, dynamic>> _items() =>
      (widget.workout['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

  String _itemName(Map<String, dynamic> item) =>
      ((item['exercise_snapshot'] as Map?)?['name_zh'])?.toString() ?? '训练动作';

  List<Map<String, dynamic>> _logs(Map<String, dynamic> item) =>
      (item['set_logs'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((log) => Map<String, dynamic>.from(log))
          .toList();

  DateTime? _started() => DateTime.tryParse('${widget.workout['started_at']}')?.toLocal();

  String _two(int value) => value.toString().padLeft(2, '0');

  String _format(DateTime date) =>
      '${date.year}-${_two(date.month)}-${_two(date.day)} ${_two(date.hour)}:${_two(date.minute)}';

  String _duration(DateTime started, DateTime ended) {
    final total = ended.difference(started).inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    return hours > 0 ? '$hours 小时 $minutes 分钟' : '$minutes 分钟';
  }

  String _logLine(Map<String, dynamic> log) {
    final values = <String>[];
    if (log['load_kg'] != null) values.add('${log['load_kg']} kg');
    if (log['reps'] != null) values.add('${log['reps']} 次');
    if (log['rpe'] != null) values.add('RPE ${log['rpe']}');
    return values.isEmpty ? '完成' : values.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final started = _started();
    final items = _items();
    final totalSets = items.fold<int>(0, (sum, item) => sum + _logs(item).length);
    return Scaffold(
      appBar: AppBar(
        title: const Text('训练完成'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.workout['plan_name']?.toString() ?? '训练',
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _TimeRow(
                          label: '开始时间',
                          value: started == null ? '—' : _format(started),
                        ),
                        const SizedBox(height: 10),
                        _TimeRow(
                          label: '结束时间',
                          value: _format(widget.endedAt),
                        ),
                        const SizedBox(height: 10),
                        _TimeRow(
                          label: '总时长',
                          value: started == null ? '—' : _duration(started, widget.endedAt),
                        ),
                        const SizedBox(height: 10),
                        _TimeRow(label: '完成组数', value: '$totalSets 组'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('训练明细', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                for (final item in items) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_itemName(item), style: const TextStyle(fontWeight: FontWeight.w800)),
                          if (_logs(item).isEmpty) ...[
                            const SizedBox(height: 6),
                            const Text('未记录组', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                          ] else ...[
                            const SizedBox(height: 8),
                            for (final log in _logs(item))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '第 ${log['set_number']} 组 · ${_logLine(log)}',
                                  style: const TextStyle(fontSize: 13, color: AppColors.text),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (widget.suggestions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('下次重量建议', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  for (final suggestion in widget.suggestions) ...[
                    _SummarySuggestionCard(
                      suggestion: suggestion,
                      repository: widget.repository,
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
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

class _TimeRow extends StatelessWidget {
  const _TimeRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      const Spacer(),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _SummarySuggestionCard extends StatelessWidget {
  const _SummarySuggestionCard({required this.suggestion, required this.repository});
  final Map<String, dynamic> suggestion;
  final TrainingRepository repository;

  @override
  Widget build(BuildContext context) {
    final suggestionData = suggestion['suggestion'] as Map? ?? const {};
    final action = suggestionData['action']?.toString() ?? 'review';
    final nextLoad = suggestionData['next_load_kg'];
    final rationale = suggestion['rationale']?.toString() ?? '';
    final name = suggestion['name_zh']?.toString() ?? '训练动作';
    final actionText = switch (action) {
      'increase_load' => '建议下次加重',
      'reduce_load' => '建议下次降低重量',
      'maintain' => '建议维持当前重量',
      _ => '建议人工复核',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                Text(
                  '$actionText${nextLoad is num ? ' · ${nextLoad.toStringAsFixed(1)} kg' : ''}',
                  style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            if (rationale.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(rationale, style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4)),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _decide(context, 'dismissed'),
                  child: const Text('忽略'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () => _decide(context, 'accepted'),
                  child: const Text('接受建议'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _decide(BuildContext context, String decision) async {
    final id = suggestion['id']?.toString();
    if (id == null) return;
    try {
      await repository.decideSuggestion(id, decision);
    } catch (_) {
      // A failed decision record never blocks closing the summary.
    }
  }
}
