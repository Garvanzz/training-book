import 'package:flutter/material.dart';

import '../../../core/data/training_repository.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/presentation/login_page.dart';
import 'attention_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _openLogin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => LoginPage(repository: widget.repository)),
    );
  }

  Future<void> _confirmSignOut() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text(
          '退出后本机会隐藏当前账号的计划与训练(不会删除)。重新登录同一账号即可恢复；若服务器暂时不可用，可在设置页“恢复本机数据”离线使用。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出登录')),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await widget.repository.signOut();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.repository,
    builder: (context, _) {
      final repository = widget.repository;
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
          children: [
            Text('设置', style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 24),
            if (repository.isSignedIn) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(repository.email ?? '已登录'),
                  subtitle: Text(
                    repository.isOwner ? 'Owner · 可管理动作库' : '普通账号 · 数据自动同步',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.sync_outlined),
                  title: const Text('离线记录同步'),
                  subtitle: Text(
                    repository.pendingOperationCount > 0
                        ? '${repository.pendingOperationCount} 条记录待同步'
                        : repository.isOnline
                        ? '已同步'
                        : '当前离线',
                  ),
                  trailing: repository.pendingOperationCount > 0
                      ? FilledButton(
                          onPressed: repository.isSyncing ? null : repository.flushQueue,
                          child: const Text('同步'),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              if (repository.attentionCount > 0)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
                    title: Text('${repository.attentionCount} 条同步记录需要处理'),
                    subtitle: const Text('查看冲突原因，选择重试或丢弃'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AttentionPage(repository: widget.repository),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _confirmSignOut,
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
              ),
            ] else ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('未登录', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      const Text(
                        '当前数据仅保存在本机。登录后会把本机的计划与训练同步到账号。',
                        style: TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _openLogin,
                        icon: const Icon(Icons.login),
                        label: const Text('登录 / 注册'),
                      ),
                      if (repository.hasRecoverableData) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: repository.resumeLocalAccount,
                          icon: const Icon(Icons.restore),
                          label: const Text('恢复本机数据（上次账号）'),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '服务器不可用或误退出时可离线使用上次账号的本机数据；联网后登录同一账号即可继续同步。',
                          style: TextStyle(color: AppColors.muted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
