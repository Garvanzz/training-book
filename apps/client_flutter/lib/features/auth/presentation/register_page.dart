import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';

/// 创建普通账号;注册成功后自动登录本机。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _displayName = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.register(
        email: _email.text,
        password: _password.text,
        displayName: _displayName.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('账号已创建并登录')),
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.statusCode == 409
              ? '这个邮箱已经注册过，请直接登录。'
              : error.statusCode == 403
                  ? '当前服务未开放自助注册。'
                  : '注册没有完成，请稍后重试（HTTP ${error.statusCode}）。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法连接本机服务，请确认后端已启动。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('注册账号')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('新账号只能使用动作库；动作管理由 Owner 账号负责。'),
                      const SizedBox(height: 22),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          hintText: 'name@example.com',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                        validator: (value) =>
                            value == null || !value.contains('@') ? '请输入有效的邮箱地址。' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _displayName,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '显示名称（可选）',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: _hidePassword,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: '密码（至少 12 位）',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                            onPressed: () => setState(() => _hidePassword = !_hidePassword),
                            icon: Icon(
                              _hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (value) =>
                            value == null || value.length < 12 ? '密码至少需要 12 个字符。' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _confirm,
                        obscureText: _hidePassword,
                        onFieldSubmitted: (_) => _register(),
                        decoration: const InputDecoration(
                          labelText: '确认密码',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        validator: (value) =>
                            value != _password.text ? '两次输入的密码不一致。' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _register,
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('注册并登录'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
