import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key, required this.repository});
  final TrainingRepository repository;
  @override State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  late final Future<List<Map<String, dynamic>>> _history = widget.repository.loadWorkoutHistory();
  DateTime _selectedDay = DateTime.now();

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _history,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        final all = (snapshot.data ?? []).where((item) => item['status'] == 'completed').toList();
        final monday = _monday(_selectedDay);
        final week = all.where((item) => _inWeek(item, monday)).toList();
        final selected = week.where((item) => _sameDay(_date(item), _selectedDay)).toList();
        final older = all.where((item) => !_inWeek(item, monday)).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(32, 28, 32, 48), children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1040), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 8),
            _WeekStrip(monday: monday, selected: _selectedDay, entries: week, onSelected: (day) => setState(() => _selectedDay = day)),
            const SizedBox(height: 24),
            Text(_dayTitle(_selectedDay), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (selected.isEmpty) const _DayEmpty() else for (final entry in selected) ...[_TrainingCard(entry: entry, onTap: () => _openDetail(entry)), const SizedBox(height: 10)],
            if (older.isNotEmpty) ...[
              const SizedBox(height: 28),
              const Text('更早记录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              for (final entry in older) ...[_TrainingCard(entry: entry, onTap: () => _openDetail(entry)), const SizedBox(height: 10)],
            ],
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 42),
                child: Center(
                  child: Text(
                    widget.repository.isSignedIn
                        ? '完成训练后，这里会按日期显示记录'
                        : '未登录 · 登录后可恢复历史记录',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ),
              ),
          ])),
        ]);
      },
    ),
  );

  Future<void> _openDetail(Map<String, dynamic> entry) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => WorkoutHistoryDetailPage(repository: widget.repository, historyEntry: entry)));
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.monday, required this.selected, required this.entries, required this.onSelected});
  final DateTime monday;
  final DateTime selected;
  final List<Map<String, dynamic>> entries;
  final ValueChanged<DateTime> onSelected;
  @override
  Widget build(BuildContext context) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 14), child: Row(children: [for (var index = 0; index < 7; index++) Expanded(child: _DayCell(label: labels[index], date: monday.add(Duration(days: index)), selected: _sameDay(selected, monday.add(Duration(days: index))), hasEntry: entries.any((entry) => _sameDay(_date(entry), monday.add(Duration(days: index)))), onTap: () => onSelected(monday.add(Duration(days: index)))))])));
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.label, required this.date, required this.selected, required this.hasEntry, required this.onTap});
  final String label;
  final DateTime date;
  final bool selected;
  final bool hasEntry;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Column(children: [Text('周$label', style: TextStyle(fontSize: 12, color: selected ? AppColors.accent : AppColors.muted, fontWeight: selected ? FontWeight.w800 : FontWeight.w500)), const SizedBox(height: 8), Container(width: 34, height: 34, alignment: Alignment.center, decoration: BoxDecoration(color: selected ? AppColors.accent : AppColors.surfaceInteractive, shape: BoxShape.circle, border: hasEntry && !selected ? Border.all(color: AppColors.accent, width: 1.5) : null), child: hasEntry ? Icon(Icons.check, size: 17, color: selected ? AppColors.accentInk : AppColors.accent) : Text('${date.day}', style: TextStyle(fontSize: 12, color: selected ? AppColors.accentInk : AppColors.muted)))])));
}

class _TrainingCard extends StatelessWidget {
  const _TrainingCard({required this.entry, required this.onTap});
  final Map<String, dynamic> entry;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final name = (entry['plan_name'] as String?)?.trim();
    final date = _date(entry);
    return Card(child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [const Icon(Icons.check_circle_outline, color: AppColors.accent), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name?.isNotEmpty == true ? name! : '训练计划', style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('${_time(date)} 开始', style: const TextStyle(color: AppColors.muted, fontSize: 12))])), const Icon(Icons.chevron_right, color: AppColors.muted)]))));
  }
}

class _DayEmpty extends StatelessWidget {
  const _DayEmpty();
  @override Widget build(BuildContext context) => Card(color: AppColors.surfaceRaised, child: const Padding(padding: EdgeInsets.all(18), child: Text('这一天没有完成训练', style: TextStyle(color: AppColors.muted))));
}

class WorkoutHistoryDetailPage extends StatelessWidget {
  const WorkoutHistoryDetailPage({super.key, required this.repository, required this.historyEntry});
  final TrainingRepository repository;
  final Map<String, dynamic> historyEntry;
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('训练记录')), body: FutureBuilder<Map<String, dynamic>>(future: repository.loadWorkoutDetail('${historyEntry['id']}'), builder: (context, snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
    if (!snapshot.hasData) return const Center(child: Text('暂时无法读取训练记录'));
    final workout = snapshot.data!;
    final items = (workout['items'] as List<dynamic>? ?? const []).whereType<Map>().map((item) => item.cast<String, dynamic>()).toList();
    final name = (historyEntry['plan_name'] as String?)?.trim();
    return ListView(padding: const EdgeInsets.all(28), children: [Text(name?.isNotEmpty == true ? name! : '训练计划', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)), const SizedBox(height: 6), Text('${_dateLabel(_date(historyEntry))} · ${_time(_date(historyEntry))}', style: const TextStyle(color: AppColors.muted)), const SizedBox(height: 20), for (var index = 0; index < items.length; index++) ...[_ActionDetail(index: index + 1, item: items[index]), const SizedBox(height: 10)]]);
   }));
}

class _ActionDetail extends StatelessWidget {
  const _ActionDetail({required this.index, required this.item});
  final int index;
  final Map<String, dynamic> item;
  @override Widget build(BuildContext context) {
    final exercise = (item['exercise_snapshot'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final logs = (item['set_logs'] as List<dynamic>? ?? const []).whereType<Map>().map((log) => log.cast<String, dynamic>()).toList();
    final actual = logs.map((log) { final values = <String>[]; if (log['load_kg'] != null) values.add('${log['load_kg']} kg'); if (log['reps'] != null) values.add('${log['reps']} 次'); if (log['rpe'] != null) values.add('RPE ${log['rpe']}'); return values.isEmpty ? '完成' : values.join(' · '); }).toList();
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('$index. ${exercise['name_zh'] ?? '训练动作'}', style: const TextStyle(fontWeight: FontWeight.w800)), if (actual.isNotEmpty) ...[const SizedBox(height: 8), Text(actual.asMap().entries.map((entry) => '${entry.key + 1}组 ${entry.value}').join('  ·  '), style: const TextStyle(color: AppColors.text))], if (actual.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('完成即可', style: TextStyle(color: AppColors.muted)))])));
  }
}

DateTime _date(Map<String, dynamic> entry) => DateTime.tryParse('${entry['started_at']}')?.toLocal() ?? DateTime.now();
DateTime _monday(DateTime date) => DateTime(date.year, date.month, date.day).subtract(Duration(days: date.weekday - 1));
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
bool _inWeek(Map<String, dynamic> entry, DateTime monday) { final date = _date(entry); return !date.isBefore(monday) && date.isBefore(monday.add(const Duration(days: 7))); }
String _time(DateTime date) => '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String _dayTitle(DateTime date) => _sameDay(date, DateTime.now()) ? '今天' : '${_dateLabel(date)}训练';
String _dateLabel(DateTime date) { const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']; return '${labels[date.weekday - 1]} · ${date.month}.${date.day}'; }
