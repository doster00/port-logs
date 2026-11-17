import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ssh_service.dart';

const _kUser = 'ssh_user';
const _kPass = 'ssh_pass';

/// Pede usuário/senha, conecta e devolve o [SshService] via Navigator.pop.
class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.host, this.label});

  final String host;
  final String? label;

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final _user = TextEditingController(text: 'ark');
  final _pass = TextEditingController(text: 'ark');
  bool _obscure = true;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final u = prefs.getString(_kUser);
      final p = prefs.getString(_kPass);
      if (!mounted) return;
      if (u != null && u.isNotEmpty) _user.text = u;
      if (p != null) _pass.text = p;
    } catch (_) {}
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final ssh = await SshService.connect(
        host: widget.host,
        username: _user.text.trim(),
        password: _pass.text,
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kUser, _user.text.trim());
        await prefs.setString(_kPass, _pass.text);
      } catch (_) {}
      if (!mounted) {
        ssh.close();
        return;
      }
      Navigator.of(context).pop(ssh);
    } on SshConnectError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_connecting,
      child: AlertDialog(
        title: Text(widget.label ?? widget.host),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.label != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(widget.host, style: theme.textTheme.bodySmall),
                ),
              TextField(
                controller: _user,
                enabled: !_connecting,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Usuário'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                enabled: !_connecting,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Senha',
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Mostrar senha' : 'Ocultar senha',
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 8),
              Text(
                'Padrão do ArkOS: ark / ark',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _connecting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: _connecting ? null : _connect,
            child: _connecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Conectar'),
          ),
        ],
      ),
    );
  }
}
