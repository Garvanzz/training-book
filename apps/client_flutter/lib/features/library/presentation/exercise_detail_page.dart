import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/api/api_client.dart' show apiBaseUrl;
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';

class ExerciseDetailPage extends StatefulWidget {
  const ExerciseDetailPage({super.key, required this.repository, required this.exerciseId});
  final TrainingRepository repository;
  final String exerciseId;

  @override
  State<ExerciseDetailPage> createState() => _ExerciseDetailPageState();
}

class _ExerciseDetailPageState extends State<ExerciseDetailPage> {
  late final Future<Map<String, dynamic>> _exercise = widget.repository.loadExerciseDetail(widget.exerciseId);
  List<String> _strings(Map<String, dynamic> data, String field) => (data[field] as List<dynamic>).cast<String>();

  Future<void> _deprecate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('下架这个动作？'),
        content: const Text('下架后新计划不能再添加它，历史训练记录不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('下架动作')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deprecateExercise(widget.exerciseId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('动作已下架，历史记录不受影响')),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂时无法下架，请检查网络后重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('动作详情'),
          actions: [
            if (widget.repository.isOwner)
              IconButton(
                tooltip: '下架动作',
                icon: const Icon(Icons.unpublished_outlined),
                onPressed: _deprecate,
              ),
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _exercise,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError || !snapshot.hasData) return const Center(child: Text('暂时无法读取动作详情。'));
            final exercise = snapshot.data!;
            final media = (exercise['media'] as List<dynamic>).cast<Map<String, dynamic>>();
            return ListView(padding: const EdgeInsets.fromLTRB(32, 28, 32, 48), children: [
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 960), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(exercise['name_zh'] as String, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                if ((exercise['summary'] as String?)?.isNotEmpty == true) ...[const SizedBox(height: 10), Text(exercise['summary'] as String, style: const TextStyle(color: AppColors.muted, fontSize: 15, height: 1.5))],
                const SizedBox(height: 24),
                _MediaGallery(media: media, repository: widget.repository),
                const SizedBox(height: 24),
                _Section(title: '动作步骤', entries: _strings(exercise, 'instructions')),
                _Section(title: '执行要点', entries: _strings(exercise, 'cues')),
                _Section(title: '常见错误', entries: _strings(exercise, 'mistakes'), icon: Icons.close_rounded, accent: AppColors.warning),
                _Section(title: '安全提示', entries: _strings(exercise, 'safety_notes'), icon: Icons.warning_amber_rounded, accent: AppColors.danger),
              ])),
            ]);
          },
        ),
      );
}

class _MediaGallery extends StatelessWidget {
  const _MediaGallery({required this.media, required this.repository});
  final List<Map<String, dynamic>> media;
  final TrainingRepository repository;
  String _key(Map<String, dynamic> item) =>
      (item['preview_object_key'] ?? item['object_key'])?.toString() ?? '';
  String _url(Map<String, dynamic> item) => '$apiBaseUrl/media/${_key(item)}';

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const _MediaEmpty();
    return Wrap(spacing: 14, runSpacing: 14, children: [
      for (final item in media)
        SizedBox(width: 290, child: Card(child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (item['media_type'] == 'image')
            AspectRatio(aspectRatio: 16 / 9, child: _ZoomableImage(url: _url(item), objectKey: _key(item), alt: item['alt_text_zh'] as String? ?? '动作图片', repository: repository))
          else
            AspectRatio(aspectRatio: 16 / 9, child: _LazyVideoMediaCard(url: _url(item), objectKey: _key(item), repository: repository)),
          Padding(padding: const EdgeInsets.all(13), child: Row(children: [Icon(item['media_type'] == 'video' ? Icons.videocam_outlined : Icons.image_outlined, size: 17, color: AppColors.accent), const SizedBox(width: 8), Expanded(child: Text(item['alt_text_zh'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))])),
        ])))),
    ]);
  }
}

class _ZoomableImage extends StatelessWidget {
  const _ZoomableImage({required this.url, required this.objectKey, required this.alt, required this.repository});
  final String url;
  final String objectKey;
  final String alt;
  final TrainingRepository repository;

  void _open(BuildContext context, String? localPath) => showDialog<void>(context: context, builder: (_) => Dialog(backgroundColor: Colors.black, insetPadding: const EdgeInsets.all(28), child: Stack(children: [
    InteractiveViewer(minScale: 0.6, maxScale: 5, child: Center(child: _image(localPath, BoxFit.contain))),
    Positioned(right: 8, top: 8, child: IconButton(tooltip: '关闭', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, color: Colors.white))),
  ])));

  Widget _image(String? localPath, BoxFit fit) {
    if (localPath != null) {
      return Image.file(File(localPath), fit: fit, errorBuilder: (_, _, _) => const _MediaFallback(icon: Icons.broken_image_outlined, text: '图片暂时无法加载'));
    }
    return Image.network(url, fit: fit, errorBuilder: (_, _, _) => const _MediaFallback(icon: Icons.broken_image_outlined, text: '图片暂时无法加载'));
  }

  @override
  Widget build(BuildContext context) {
    // Try the local cache first so offline detail pages still show media.
    return FutureBuilder<String?>(
      future: repository.ensureMediaCached(objectKey),
      builder: (context, snapshot) {
        final localPath = snapshot.data;
        return InkWell(onTap: () => _open(context, localPath), child: Stack(fit: StackFit.expand, children: [
          _image(localPath, BoxFit.cover),
          const Positioned(right: 8, top: 8, child: Icon(Icons.zoom_in, color: Colors.white)),
        ]));
      },
    );
  }
}

class _LazyVideoMediaCard extends StatefulWidget {
  const _LazyVideoMediaCard({required this.url, required this.objectKey, required this.repository});
  final String url;
  final String objectKey;
  final TrainingRepository repository;
  @override
  State<_LazyVideoMediaCard> createState() => _LazyVideoMediaCardState();
}

class _LazyVideoMediaCardState extends State<_LazyVideoMediaCard> {
  Player? _player;
  VideoController? _controller;
  bool _loading = false;

  Future<void> _start() async {
    setState(() => _loading = true);
    // Cache the video locally before playing: gyms are often offline and a
    // cached copy survives both reconnects and repeated views.
    final localPath = await widget.repository.ensureMediaCached(widget.objectKey);
    if (!mounted) return;
    final player = Player();
    final controller = VideoController(player);
    setState(() {
      _player = player;
      _controller = controller;
      _loading = false;
    });
    await player.open(Media(localPath ?? widget.url), play: false);
  }

  @override
  void dispose() { _player?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_controller != null) return Video(controller: _controller!, controls: MaterialVideoControls, fill: AppColors.surfaceInteractive);
    return ColoredBox(color: AppColors.surfaceInteractive, child: Center(child: FilledButton.icon(
      onPressed: _loading ? null : _start,
      icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
      label: Text(_loading ? '正在缓存视频…' : '加载视频'),
    )));
  }
}

class _MediaEmpty extends StatelessWidget {
  const _MediaEmpty();
  @override
  Widget build(BuildContext context) => const Card(child: Padding(padding: EdgeInsets.all(20), child: Row(children: [Icon(Icons.perm_media_outlined, color: AppColors.muted), SizedBox(width: 12), Text('暂无可用媒体。', style: TextStyle(color: AppColors.muted))])));
}

class _MediaFallback extends StatelessWidget {
  const _MediaFallback({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => ColoredBox(color: AppColors.surfaceInteractive, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 34, color: AppColors.muted), const SizedBox(height: 8), Text(text, style: const TextStyle(color: AppColors.muted))])));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.entries, this.icon = Icons.check_rounded, this.accent = AppColors.accent});
  final String title;
  final List<String> entries;
  final IconData icon;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 18), child: Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)), const SizedBox(height: 13), for (final entry in entries) Padding(padding: const EdgeInsets.only(bottom: 9), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 17, color: accent), const SizedBox(width: 9), Expanded(child: Text(entry, style: const TextStyle(height: 1.45)))]))]))));
  }
}
