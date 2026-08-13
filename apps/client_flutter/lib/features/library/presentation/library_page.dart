import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import 'exercise_detail_page.dart';
import 'quick_exercise_editor_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.repository});
  final TrainingRepository repository;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late Future<List<Map<String, dynamic>>> _published = widget.repository
      .loadExercises();
  late Future<List<Map<String, dynamic>>> _drafts = widget.repository
      .loadExerciseDrafts();
  String _search = '';
  String? _purpose;
  late final Future<List<Map<String, dynamic>>> _taxonomy = widget.repository
      .loadTaxonomy();

  void _reload([String? search]) => setState(() {
    _search = search ?? _search;
    _published = widget.repository.loadExercises(
      search: _search.isEmpty ? null : _search,
      purpose: _purpose,
    );
    _drafts = widget.repository.loadExerciseDrafts();
  });

  Future<void> _openEditor({Map<String, dynamic>? draft}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QuickExerciseEditorPage(
          repository: widget.repository,
          exerciseId: draft?['id'] as String?,
          versionNo: draft?['version_no'] as int?,
        ),
      ),
    );
    if (changed == true && mounted) _reload();
  }

  void _openPublished(Map<String, dynamic> exercise) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExerciseDetailPage(
            repository: widget.repository,
            exerciseId: exercise['id'] as String,
          ),
        ),
      );

  Future<void> _createRevision(Map<String, dynamic> exercise) async {
    try {
      final draft = await widget.repository.createExerciseRevisionDraft(
        exercise['id'] as String,
      );
      if (mounted) await _openEditor(draft: draft);
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法创建修订（HTTP ${error.statusCode}）')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: FutureBuilder<List<Map<String, dynamic>>>(
      future: _published,
      builder: (context, publishedSnapshot) =>
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _drafts,
            builder: (context, draftSnapshot) {
              final published =
                  publishedSnapshot.data ?? const <Map<String, dynamic>>[];
              final drafts =
                  draftSnapshot.data ?? const <Map<String, dynamic>>[];
              final loading =
                  publishedSnapshot.connectionState ==
                      ConnectionState.waiting ||
                  draftSnapshot.connectionState == ConnectionState.waiting;
              return ListView(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 48),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1240),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '动作库',
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (widget.repository.isOwner && drafts.isNotEmpty)
                              _DraftShortcut(
                                count: drafts.length,
                                onTap: () => _openDrafts(context, drafts),
                              ),
                            if (widget.repository.isOwner) ...[const SizedBox(width: 10), FilledButton.icon(
                              onPressed: _openEditor,
                              icon: const Icon(Icons.add),
                              label: const Text('新增动作'),
                            )],
                          ],
                        ),
                        const SizedBox(height: 24),
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: _taxonomy,
                          builder: (context, snapshot) => _FilterBar(
                            terms: snapshot.data ?? const [],
                            purpose: _purpose,
                            onChanged: (purpose) {
                              setState(() => _purpose = purpose);
                              _reload();
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        _PublishedContent(
                          loading: loading,
                          exercises: published,
                          search: _search,
                          onSearch: _reload,
                          onOpen: _openPublished,
                          onRevise: widget.repository.isOwner ? _createRevision : null,
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

  Future<void> _openDrafts(
    BuildContext context,
    List<Map<String, dynamic>> drafts,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          shrinkWrap: true,
          children: [
            const Text(
              '未发布草稿',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            for (final draft in drafts)
              ListTile(
                onTap: () {
                  Navigator.pop(context);
                  _openEditor(draft: draft);
                },
                leading: const Icon(
                  Icons.edit_note_outlined,
                  color: AppColors.warning,
                ),
                title: Text(
                  (draft['name_zh'] as String?)?.trim().isNotEmpty == true
                      ? draft['name_zh'] as String
                      : '未命名动作',
                ),
                subtitle:
                    ((draft['summary'] as String?)?.trim().isNotEmpty == true)
                    ? Text((draft['summary'] as String).trim())
                    : null,
                trailing: const Icon(Icons.chevron_right),
              ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _LibraryTab extends StatelessWidget {
  const _LibraryTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: selected ? AppColors.surfaceInteractive : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? AppColors.accent : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected ? AppColors.accent : AppColors.text,
            ),
          ),
          const Spacer(),
          _CountBadge(value: count),
        ],
      ),
    ),
  );
}

class _DraftShortcut extends StatelessWidget {
  const _DraftShortcut({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.edit_note_outlined, size: 18),
    label: Text('草稿 $count'),
  );
}

class _PublishedContent extends StatelessWidget {
  const _PublishedContent({
    required this.loading,
    required this.exercises,
    required this.search,
    required this.onSearch,
    required this.onOpen,
    required this.onRevise,
  });
  final bool loading;
  final List<Map<String, dynamic>> exercises;
  final String search;
  final ValueChanged<String> onSearch;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final ValueChanged<Map<String, dynamic>>? onRevise;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        onSubmitted: onSearch,
        decoration: InputDecoration(
          hintText: '搜索动作名称',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: search.isEmpty
              ? null
              : IconButton(
                  onPressed: () => onSearch(''),
                  icon: const Icon(Icons.clear),
                ),
        ),
      ),
      const SizedBox(height: 18),
      if (loading)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: CircularProgressIndicator(),
          ),
        )
      else if (exercises.isEmpty)
        const _Empty(text: '还没有已发布动作')
      else
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 980
                ? 3
                : constraints.maxWidth >= 640
                ? 2
                : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: exercises.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.45,
              ),
              itemBuilder: (context, index) => _ExerciseCard(
                exercise: exercises[index],
                onOpen: () => onOpen(exercises[index]),
                onRevise: onRevise == null ? null : () => onRevise!(exercises[index]),
              ),
            );
          },
        ),
    ],
  );
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.exercise,
    required this.onOpen,
    required this.onRevise,
  });
  final Map<String, dynamic> exercise;
  final VoidCallback onOpen;
  final VoidCallback? onRevise;
  @override
  Widget build(BuildContext context) {
    final name = (exercise['name_zh'] as String?)?.trim();
    final summary = (exercise['summary'] as String?)?.trim();
    final purposes = (exercise['purposes'] as List<dynamic>? ?? const [])
        .cast<String>();
    final canRevise = onRevise != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: AppColors.surfaceInteractive,
                child: const Center(
                  child: Icon(
                    Icons.fitness_center_outlined,
                    size: 42,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name?.isNotEmpty == true ? name! : '未命名动作',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (purposes.isNotEmpty ||
                            summary?.isNotEmpty == true) ...[
                          const SizedBox(height: 4),
                          Text(
                            purposes.isEmpty
                                ? summary!
                                : _purposeLabel(purposes.first),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    enabled: canRevise,
                    onSelected: (_) => onRevise?.call(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'revise', child: Text('创建修订')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _DraftContent extends StatelessWidget {
  const _DraftContent({
    required this.loading,
    required this.drafts,
    required this.onOpen,
  });
  final bool loading;
  final List<Map<String, dynamic>> drafts;
  final ValueChanged<Map<String, dynamic>> onOpen;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (loading)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: CircularProgressIndicator(),
          ),
        )
      else if (drafts.isEmpty)
        const _Empty(text: '暂无草稿。新建动作后，未发布内容会显示在这里。')
      else
        for (final draft in drafts)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: ListTile(
                onTap: () => onOpen(draft),
                leading: const Icon(
                  Icons.edit_note_outlined,
                  color: AppColors.warning,
                ),
                title: Text(
                  (draft['name_zh'] as String?)?.trim().isNotEmpty == true
                      ? draft['name_zh'] as String
                      : '未命名动作',
                ),
                subtitle: Text(
                  (draft['summary'] as String?)?.trim().isNotEmpty == true
                      ? draft['summary'] as String
                      : '尚未填写摘要',
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          ),
    ],
  );
}

String _purposeLabel(String value) => switch (value) {
  'general_warmup' => '热身',
  'mobility' => '活动度',
  'activation_control' => '激活与控制',
  'primary_strength' => '力量训练',
  'accessory' => '辅助训练',
  'conditioning' => '体能',
  _ => '训练动作',
};

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.value});
  final int value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.surfaceInteractive,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      '$value',
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(
      child: Text(text, style: const TextStyle(color: AppColors.muted)),
    ),
  );
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.terms,
    required this.purpose,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> terms;
  final String? purpose;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final purposes = terms.where((term) => term['dimension'] == 'purpose').toList();
    if (purposes.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DropdownButton<String?>(
          value: purpose,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('阶段用途：全部')),
            for (final term in purposes)
              DropdownMenuItem<String?>(
                value: term['code']?.toString(),
                child: Text(term['name_zh']?.toString() ?? ''),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}
