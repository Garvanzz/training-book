import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

/// 同步冲突/被拒绝操作的决策列表:查看原因,选择重试或丢弃。
class AttentionPage extends StatefulWidget {
  const AttentionPage({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<AttentionPage> createState() => _AttentionPageState();
}

class _AttentionPageState extends State<AttentionPage> {
  late Future<List<Map<String, dynamic>>> _operations = widget.repository.attentionOperations();

  void _reload() => setState(() => _operations = widget.repository.attentionOperations());

  Future<void> _retry(Map<String, dynamic> operation) async {
    await widget.repository.retryAttentionOperation(operation['operation_id'] as String);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已重新提交，结果见同步状态')),
      );
      _reload();
    }
  }

  Future<void> _discard(Map<String, dynamic> operation) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('丢弃这条记录？'),
        content: const Text('丢弃后对应的本地变更不会再上传，此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('丢弃')),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await widget.repository.discardAttentionOperation(operation['operation_id'] as String);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('需要处理的同步记录')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _operations,
      builder: (context, snapshot) {
        final operations = snapshot.data ?? const <Map<String, dynamic>>[];
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (operations.isEmpty) {
          return const Center(
            child: Text('没有需要处理的记录', style: TextStyle(color: AppColors.muted)),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '这些本地变更被服务器拒绝或冲突。你可以重试,或丢弃(数据丢失)。',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            for (final operation in operations) ...[
              _AttentionCard(
                operation: operation,
                onRetry: () => _retry(operation),
                onDiscard: () => _discard(operation),
              ),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    ),
  );
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.operation, required this.onRetry, required this.onDiscard});
  final Map<String, dynamic> operation;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  static const _entityNames = {
    'plan': '计划',
    'workout_session': '训练',
    'set_log': '组记录',
  };
  static const _operationNames = {
    'create': '创建',
    'update': '修改',
    'delete': '删除',
  };

  String get _entityName =>
      _entityNames[operation['entity_type']?.toString()] ?? operation['entity_type']?.toString() ?? '未知';
  String get _operationName =>
      _operationNames[operation['operation_type']?.toString()] ?? operation['operation_type']?.toString() ?? '操作';

  String get _reason {
    final raw = operation['last_error']?.toString();
    if (raw == null || raw.isEmpty) return '未知原因';
    try {
      final detail = jsonDecode(raw);
      if (detail is Map) {
        final reason = detail['reason']?.toString();
        if (reason != null) return _reasonText(reason);
      }
      return raw;
    } on FormatException {
      return raw;
    }
  }

  String _reasonText(String reason) => switch (reason) {
        'plan_changed_on_server' => '计划已在其他设备修改(版本冲突),重试会以最新版本为准失败;如需覆盖请先在其他设备查看该计划。',
        'plan_draft_unavailable' => '该计划已有一个未发布的草稿,暂时无法替换。',
        'plan_not_found' => '计划不存在或已删除。',
        'workout_not_in_progress' => '这次训练已经结束,无需再次完成/放弃。',
        'already_active_workout' => '已经有一场进行中的训练,无法再开始。',
        'workout_start_failed' => '开始训练失败:计划可能已下架或没有可执行动作。',
        'invalid_plan_blocks' => '计划内容无效:包含已下架或不存在的动作。',
        'update_requires_base_revision' => '修改缺少版本信息,无法同步。',
        'unsupported_entity_type' => '服务器不支持这种数据类型。',
        _ => reason,
      };

  String get _time {
    final updatedAt = operation['updated_at'];
    if (updatedAt is! int) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(updatedAt).toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$_entityName · $_operationName',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Text(_time, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 8),
          Text(_reason, style: const TextStyle(fontSize: 12, color: AppColors.muted, height: 1.4)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onDiscard, child: const Text('丢弃')),
              const SizedBox(width: 6),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ],
      ),
    ),
  );
}
