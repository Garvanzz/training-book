import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

/// 快速创建动作。动作库只要求一个名称，其余内容按需补充。
class QuickExerciseEditorPage extends StatefulWidget {
  const QuickExerciseEditorPage({
    super.key,
    required this.repository,
    this.exerciseId,
    this.versionNo,
  });

  final TrainingRepository repository;
  final String? exerciseId;
  final int? versionNo;

  @override
  State<QuickExerciseEditorPage> createState() =>
      _QuickExerciseEditorPageState();
}

class _QuickExerciseEditorPageState extends State<QuickExerciseEditorPage> {
  final _name = TextEditingController();
  final _keyPoint = TextEditingController();
  String? _purpose;
  String? _id;
  int? _version;
  List<Map<String, dynamic>> _media = [];
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _persisted => _id != null && _version != null;

  @override
  void initState() {
    super.initState();
    _id = widget.exerciseId;
    _version = widget.versionNo;
    if (_persisted) _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _keyPoint.dispose();
    super.dispose();
  }

  String? _firstString(List<dynamic>? values) {
    for (final value in values ?? const <dynamic>[]) {
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final draft = await widget.repository.loadExerciseDraft(
        exerciseId: _id!,
        versionNo: _version!,
      );
      _name.text = draft['name_zh'] as String? ?? '';
      _keyPoint.text =
          _firstString(draft['instructions'] as List<dynamic>?) ??
          _firstString(draft['cues'] as List<dynamic>?) ??
          '';
      final tags =
          (draft['tags'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      _purpose = _firstString(tags['purpose'] as List<dynamic>?);
      _media = (draft['media'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _apiErrorMessage(error, '读取草稿'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _payload() => {
    'name_zh': _name.text.trim(),
    'name_en': null,
    'summary': '',
    'recording_mode': 'load_reps',
    'instructions': _keyPoint.text.trim().isEmpty
        ? <String>[]
        : <String>[_keyPoint.text.trim()],
    'cues': <String>[],
    'mistakes': <String>[],
    'safety_notes': <String>[],
    'tags': _purpose == null
        ? <String, List<String>>{}
        : <String, List<String>>{
            'purpose': <String>[_purpose!],
          },
    'media': <Map<String, dynamic>>[],
    'change_summary': '更新动作内容',
  };

  String _apiErrorMessage(ApiException error, String action) {
    try {
      final body = jsonDecode(error.message);
      final detail = body is Map<String, dynamic> ? body['detail'] : null;
      if (detail is String && detail.trim().isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) {
        return detail['message'] as String;
      }
    } catch (_) {
      // Some clients return a plain-text error body.
    }
    return '$action失败，请稍后重试（HTTP ${error.statusCode}）';
  }

  Future<bool> _saveDraft({bool quiet = false}) async {
    if (_name.text.trim().isEmpty) {
      if (mounted) setState(() => _error = '请先填写动作名称');
      return false;
    }
    if (mounted) {
      setState(() {
        _saving = true;
        _error = null;
      });
    }
    try {
      if (_persisted) {
        await widget.repository.updateExerciseDraft(
          exerciseId: _id!,
          versionNo: _version!,
          draft: _payload(),
        );
      } else {
        final created = await widget.repository.createExerciseDraft(_payload());
        _id = created['id'] as String?;
        _version = (created['version_no'] as num?)?.toInt();
      }
      if (!quiet && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('草稿已保存'),
            duration: Duration(seconds: 1),
          ),
        );
      }
      return true;
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _apiErrorMessage(error, '保存草稿'));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMedia() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '动作演示',
          extensions: [
            'mp4',
            'mov',
            'm4v',
            'webm',
            'avi',
            'mkv',
            'jpg',
            'jpeg',
            'png',
            'webp',
          ],
        ),
      ],
    );
    if (file == null || !mounted) return;
    if (!await _saveDraft(quiet: true)) return;
    if (mounted) setState(() => _saving = true);
    try {
      final extension = file.path.split('.').last.toLowerCase();
      final mediaType = {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)
          ? 'image'
          : 'video';
      final media = await widget.repository.uploadExerciseMedia(
        exerciseId: _id!,
        versionNo: _version!,
        filePath: file.path,
        altText: '动作演示',
        mediaType: mediaType,
      );
      if (mounted) setState(() => _media.add(media));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _apiErrorMessage(error, '上传演示'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeMedia(Map<String, dynamic> media) async {
    final mediaId = media['id'] as String?;
    if (mediaId == null) return;
    if (mounted) setState(() => _saving = true);
    try {
      await widget.repository.deleteExerciseMedia(mediaId);
      if (mounted) {
        setState(() => _media.removeWhere((item) => item['id'] == mediaId));
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _apiErrorMessage(error, '删除演示'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publish() async {
    if (!await _saveDraft(quiet: true)) return;
    if (mounted) setState(() => _saving = true);
    try {
      await widget.repository.publishExercise(
        exerciseId: _id!,
        versionNo: _version!,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _apiErrorMessage(error, '发布动作'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _mediaCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(
                  Icons.ondemand_video_outlined,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _media.isEmpty ? '动作演示' : '动作演示 · ${_media.length}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: _saving ? null : _addMedia,
                  tooltip: '添加演示',
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (_media.isNotEmpty) ...[
              const Divider(height: 1),
              for (final media in _media)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    media['media_type'] == 'video'
                        ? Icons.play_circle_outline
                        : Icons.image_outlined,
                    color: AppColors.accent,
                  ),
                  title: Text(
                    (media['alt_text_zh'] as String?)?.trim().isNotEmpty == true
                        ? media['alt_text_zh'] as String
                        : '动作演示',
                  ),
                  trailing: IconButton(
                    onPressed: _saving ? null : () => _removeMedia(media),
                    tooltip: '移除',
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_persisted ? '编辑动作' : '新增动作'),
        actions: [
          TextButton(
            onPressed: _saving || _loading
                ? null
                : () async {
                    final navigator = Navigator.of(context);
                    final saved = await _saveDraft();
                    if (saved && mounted) navigator.pop(true);
                  },
            child: const Text('保存草稿'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 700),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: '动作名称'),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String?>(
                        initialValue: _purpose,
                        decoration: const InputDecoration(labelText: '训练分类'),
                        items: const [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text('不设置'),
                          ),
                          DropdownMenuItem(
                            value: 'general_warmup',
                            child: Text('热身'),
                          ),
                          DropdownMenuItem(
                            value: 'mobility',
                            child: Text('活动度'),
                          ),
                          DropdownMenuItem(
                            value: 'activation_control',
                            child: Text('激活与控制'),
                          ),
                          DropdownMenuItem(
                            value: 'primary_strength',
                            child: Text('力量训练'),
                          ),
                          DropdownMenuItem(
                            value: 'accessory',
                            child: Text('辅助训练'),
                          ),
                          DropdownMenuItem(
                            value: 'conditioning',
                            child: Text('体能'),
                          ),
                          DropdownMenuItem(
                            value: 'cooldown_recovery',
                            child: Text('恢复'),
                          ),
                        ],
                        onChanged: (value) => setState(() => _purpose = value),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _keyPoint,
                        maxLines: 3,
                        decoration: const InputDecoration(labelText: '动作要点'),
                      ),
                      const SizedBox(height: 16),
                      _mediaCard(),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _publish,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.publish),
                          label: const Text('发布动作'),
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
