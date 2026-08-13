import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';

class ExerciseEditorPage extends StatefulWidget {
  const ExerciseEditorPage({
    super.key,
    required this.repository,
    this.exerciseId,
    this.versionNo,
  });
  final TrainingRepository repository;
  final String? exerciseId;
  final int? versionNo;

  @override
  State<ExerciseEditorPage> createState() => _ExerciseEditorPageState();
}

class _ExerciseEditorPageState extends State<ExerciseEditorPage> {
  final _name = TextEditingController();
  final _summary = TextEditingController();
  final _keyPoint = TextEditingController();
  final _mediaAlt = TextEditingController();
  final List<TextEditingController> _instructions = [];
  final List<TextEditingController> _cues = [];
  final List<TextEditingController> _mistakes = [];
  final List<TextEditingController> _safety = [];
  final List<Map<String, dynamic>> _media = [];
  String? _exerciseId;
  int? _versionNo;
  String? _purpose;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _isPersisted => _exerciseId != null && _versionNo != null;

  String _friendlyError(ApiException error, {required String action}) {
    if (error.statusCode == 401) return '登录已过期，请重新登录后再$action。';
    if (error.statusCode == 404) return '没有找到这份草稿，刷新动作库后重试。';
    if (error.statusCode == 409) return '这份动作正在被其他版本编辑，请刷新后再试。';
    if (error.statusCode == 422) {
      try {
        final decoded = jsonDecode(error.message);
        final detail = decoded is Map ? decoded['detail'] : null;
        if (detail is Map && detail['missing'] is List) {
          return '暂时不能$action：${(detail['missing'] as List).join('、')}。';
        }
      } catch (_) {}
      return '请检查当前填写内容后再$action。';
    }
    return '暂时无法$action，请确认本机服务正常后重试。';
  }

  @override
  void initState() {
    super.initState();
    _exerciseId = widget.exerciseId;
    _versionNo = widget.versionNo;
    if (_isPersisted) _loadDraft();
  }

  @override
  void dispose() {
    for (final controller in [_name, _summary, _keyPoint, _mediaAlt, ..._instructions, ..._cues, ..._mistakes, ..._safety]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDraft() async {
    setState(() => _loading = true);
    try {
      final draft = await widget.repository.loadExerciseDraft(exerciseId: _exerciseId!, versionNo: _versionNo!);
      _name.text = (draft['name_zh'] as String?) ?? '';
      _summary.text = (draft['summary'] as String?) ?? '';
      final purposes = ((draft['tags'] as Map<String, dynamic>)['purpose'] as List<dynamic>?)?.cast<String>() ?? [];
      _purpose = purposes.isEmpty ? null : purposes.first;
      _replaceLines(_instructions, ((draft['instructions'] as List<dynamic>?) ?? []).whereType<String>().toList());
      _replaceLines(_cues, ((draft['cues'] as List<dynamic>?) ?? []).whereType<String>().toList());
      _replaceLines(_mistakes, ((draft['mistakes'] as List<dynamic>?) ?? []).whereType<String>().toList());
      _replaceLines(_safety, ((draft['safety_notes'] as List<dynamic>?) ?? []).whereType<String>().toList());
      _keyPoint.text = _instructions.firstOrNull?.text ?? _cues.firstOrNull?.text ?? '';
      _media
        ..clear()
        ..addAll(((draft['media'] as List<dynamic>?) ?? []).map((item) => Map<String, dynamic>.from(item as Map)));
    } on ApiException catch (error) {
      _error = '读取草稿失败（HTTP ${error.statusCode}）。';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _replaceLines(List<TextEditingController> target, List<String> values) {
    for (final controller in target) {
      controller.dispose();
    }
    target
      ..clear()
      ..addAll(values.map((value) => TextEditingController(text: value)));
  }

  List<String> _values(List<TextEditingController> controllers) => controllers
      .map((controller) => controller.text.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  Map<String, dynamic> _payload() => {
    'name_zh': _name.text.trim(),
    'name_en': null,
    'summary': _summary.text.trim(),
    'recording_mode': 'load_reps',
    'instructions': _keyPoint.text.trim().isEmpty ? _values(_instructions) : [_keyPoint.text.trim()],
    'cues': _values(_cues),
    'mistakes': _values(_mistakes),
    'safety_notes': _values(_safety),
    'tags': _purpose == null ? <String, List<String>>{} : {'purpose': [_purpose!]},
    'media': [],
    'change_summary': '所有者更新草稿',
  };

  Future<bool> _saveDraft({bool quiet = false}) async {
    if (_name.text.trim().length < 2) {
      setState(() => _error = '草稿至少需要一个动作名称。');
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isPersisted) {
        await widget.repository.updateExerciseDraft(exerciseId: _exerciseId!, versionNo: _versionNo!, draft: _payload());
      } else {
        final created = await widget.repository.createExerciseDraft(_payload());
        _exerciseId = created['id'] as String;
        _versionNo = created['version_no'] as int;
      }
      if (!quiet && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('草稿已保存。')));
      }
      return true;
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error, action: '保存草稿'));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMedia() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '动作视频或图片', extensions: ['mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv', 'jpg', 'jpeg', 'png', 'webp']),
      ],
    );
    if (file == null) return;
    if (!await _saveDraft(quiet: true)) return;
    setState(() => _saving = true);
    try {
      final media = await widget.repository.uploadExerciseMedia(
        exerciseId: _exerciseId!,
        versionNo: _versionNo!,
        filePath: file.path,
        altText: _mediaAlt.text.trim().isEmpty ? '动作演示媒体文件' : _mediaAlt.text.trim(),
      );
      if (mounted) {
        setState(() {
          _media.add(media);
          _mediaAlt.clear();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error, action: '上传媒体'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publish() async {
    if (!await _saveDraft(quiet: true)) return;
    setState(() => _saving = true);
    try {
      await widget.repository.publishExercise(exerciseId: _exerciseId!, versionNo: _versionNo!);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error, action: '发布动作'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAndExit() async {
    if (await _saveDraft() && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _removeMedia(Map<String, dynamic> media) async {
    final mediaId = media['id'] as String?;
    if (mediaId == null) return;
    setState(() => _saving = true);
    try {
      await widget.repository.deleteExerciseMedia(mediaId);
      if (mounted) setState(() => _media.removeWhere((item) => item['id'] == mediaId));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error, action: '删除媒体'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _discardDraft() async {
    if (!_isPersisted) { Navigator.of(context).pop(false); return; }
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('放弃此草稿？'), content: const Text('草稿中的未发布文字和媒体引用将被删除；已发布版本不会受影响。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('放弃草稿'))]));
    if (confirmed != true) return;
    setState(() => _saving = true);
    try { await widget.repository.deleteExerciseDraft(exerciseId: _exerciseId!, versionNo: _versionNo!); if (mounted) Navigator.of(context).pop(true); } on ApiException catch (error) { if (mounted) setState(() => _error = _friendlyError(error, action: '放弃草稿')); } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_isPersisted ? '编辑动作草稿' : '新增动作草稿'),
      actions: [
        if (_isPersisted) IconButton(tooltip: '放弃草稿', onPressed: _saving || _loading ? null : _discardDraft, icon: const Icon(Icons.delete_outline)),
        TextButton.icon(onPressed: _saving || _loading ? null : _saveAndExit, icon: const Icon(Icons.save_outlined), label: const Text('保存草稿')),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              children: [
                const SizedBox(height: 4),
                TextField(controller: _name, decoration: const InputDecoration(labelText: '动作名称 *', hintText: '例如：杠铃深蹲')),
                const SizedBox(height: 12),
                TextField(controller: _summary, maxLines: 2, decoration: const InputDecoration(labelText: '简述', hintText: '说明这个动作主要练什么、用于什么阶段。')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  key: ValueKey(_purpose),
                  initialValue: _purpose,
                  decoration: const InputDecoration(labelText: '主要训练阶段（可稍后选择）'),
                  items: const [
                    DropdownMenuItem<String?>(value: null, child: Text('暂不设置')),
                    DropdownMenuItem(value: 'general_warmup', child: Text('一般热身')),
                    DropdownMenuItem(value: 'mobility', child: Text('活动度')),
                    DropdownMenuItem(value: 'activation_control', child: Text('激活与控制')),
                    DropdownMenuItem(value: 'primary_strength', child: Text('主力量')),
                    DropdownMenuItem(value: 'accessory', child: Text('辅助力量')),
                    DropdownMenuItem(value: 'conditioning', child: Text('有氧/体能')),
                    DropdownMenuItem(value: 'cooldown_recovery', child: Text('冷身恢复')),
                  ],
                  onChanged: (value) => setState(() => _purpose = value),
                ),
                const SizedBox(height: 20),
                _LineSection(title: '动作步骤', hint: '例如：双脚与髋同宽站立', controllers: _instructions, onChanged: () => setState(() {})),
                _LineSection(title: '执行要点', hint: '例如：保持躯干稳定', controllers: _cues, onChanged: () => setState(() {})),
                _LineSection(title: '常见错误', hint: '例如：腰背代偿', controllers: _mistakes, onChanged: () => setState(() {})),
                _LineSection(title: '安全提示', hint: '例如：出现锐痛时停止', controllers: _safety, onChanged: () => setState(() {})),
                const SizedBox(height: 20),
                Text('媒体（可后补）', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                TextField(controller: _mediaAlt, decoration: const InputDecoration(labelText: '本次媒体说明', hintText: '例如：侧面完整动作演示')),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: _saving ? null : _addMedia, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('添加视频或图片（可选）')),
                for (final media in _media)
                  ListTile(leading: Icon(media['media_type'] == 'video' ? Icons.play_circle_outline : Icons.image_outlined), title: Text(media['alt_text_zh'] as String), subtitle: Text(media['content_type'] as String), trailing: IconButton(tooltip: '移除此媒体', onPressed: _saving ? null : () => _removeMedia(media), icon: const Icon(Icons.delete_outline))),
                if (_error != null) ...[const SizedBox(height: 18), Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
                const SizedBox(height: 28),
                FilledButton.icon(onPressed: _saving ? null : _publish, icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.publish), label: const Text('发布动作')),
              ],
            ),
          ),
  );
}

class _LineSection extends StatelessWidget {
  const _LineSection({required this.title, required this.hint, required this.controllers, required this.onChanged});
  final String title;
  final String hint;
  final List<TextEditingController> controllers;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)), IconButton(tooltip: '添加一行', onPressed: () { controllers.add(TextEditingController()); onChanged(); }, icon: const Icon(Icons.add_circle_outline))]),
        if (controllers.isEmpty) Text('尚未填写；点击右侧 + 添加。', style: Theme.of(context).textTheme.bodySmall),
        for (var index = 0; index < controllers.length; index++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(child: TextField(controller: controllers[index], decoration: InputDecoration(hintText: hint))),
                IconButton(tooltip: '删除这一行', onPressed: () { controllers[index].dispose(); controllers.removeAt(index); onChanged(); }, icon: const Icon(Icons.remove_circle_outline)),
              ],
            ),
          ),
      ],
    ),
  );
}
