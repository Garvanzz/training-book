import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/data/training_repository.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.repository});
  final TrainingRepository repository;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  bool _rememberCredentials = true;
  bool _registrationEnabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreRememberedCredentials();
    widget.repository.fetchRegistrationStatus().then((enabled) {
      if (mounted) setState(() => _registrationEnabled = enabled);
    });
  }

  Future<void> _restoreRememberedCredentials() async {
    final credentials = await widget.repository.rememberedCredentials();
    if (!mounted || credentials == null) return;
    setState(() {
      _email.text = credentials.email;
      _password.text = credentials.password;
      _rememberCredentials = true;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.signIn(
        email: _email.text,
        password: _password.text,
      );
      await widget.repository.rememberCredentials(email: _email.text, password: _password.text, enabled: _rememberCredentials);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error.statusCode == 401
                  ? '邮箱或密码不正确，请重新输入。'
                  : error.statusCode == 422
                      ? '请检查邮箱和密码格式。'
                      : '暂时无法完成登录，请确认本机服务已启动后重试。',
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
    appBar: AppBar(title: const Text('登录')),
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
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(
                          Icons.menu_book_rounded,
                          size: 40,
                          color: Color(0xFF5DD6B0),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          '登录训练簿',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text('记录计划、完成训练，并保留每一次重量调整的依据。'),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _email,
                          autofillHints: const [
                            AutofillHints.username,
                            AutofillHints.email,
                          ],
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '邮箱',
                            hintText: 'name@example.com',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                          validator: (value) =>
                              value == null || !value.contains('@')
                              ? '请输入有效的邮箱地址。'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _password,
                          obscureText: _hidePassword,
                          autofillHints: const [AutofillHints.password],
                          onFieldSubmitted: (_) => _login(),
                          decoration: InputDecoration(
                            labelText: '密码',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                              onPressed: () => setState(
                                () => _hidePassword = !_hidePassword,
                              ),
                              icon: Icon(
                                _hidePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) =>
                              value == null || value.isEmpty ? '请输入密码。' : null,
                        ),
                        CheckboxListTile(
                          value: _rememberCredentials,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('记住账号和密码'),
                          subtitle: const Text('仅保存在此设备的系统安全存储中。'),
                          onChanged: (value) => setState(() => _rememberCredentials = value ?? false),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _busy ? null : _login,
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('登录'),
                        ),
                        if (_registrationEnabled)
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => RegisterPage(repository: widget.repository),
                              ),
                            ),
                            icon: const Icon(Icons.person_add_outlined),
                            label: const Text('注册账号'),
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
    ),
  );
}
