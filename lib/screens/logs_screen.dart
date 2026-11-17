import 'package:flutter/material.dart';

import '../services/ssh_service.dart';
import '../utils/format.dart';
import '../widgets/state_views.dart';
import 'log_viewer_screen.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.ssh, required this.port});

  final SshService ssh;
  final PortEntry port;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<LogFile>? _files;
  String? _error;
  bool _allText = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final request = ++_request;
    try {
      final files = await widget.ssh.findLogs(widget.port.path, allText: _allText);
      if (mounted && request == _request) setState(() => _files = files);
    } catch (e) {
      if (mounted && request == _request) setState(() => _error = '$e');
    }
  }

  void _reload() {
    setState(() {
      _files = null;
      _error = null;
    });
    _fetch();
  }

  void _setAllText(bool value) {
    _allText = value;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TwoLineTitle(widget.port.name, widget.port.path),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            value: _allText,
            onChanged: _setAllText,
            title: const Text('Mostrar todos os arquivos de texto'),
            subtitle: Text(
              _allText
                  ? 'Todos os .txt, .log, .out e .err'
                  : 'Só arquivos com log, report, crash, error ou debug no nome',
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return MessageView(
        icon: Icons.error_outline,
        title: 'Não foi possível procurar os logs',
        message: _error,
        actionLabel: 'Tentar de novo',
        onAction: _reload,
        isError: true,
      );
    }
    final files = _files;
    if (files == null) return const Center(child: CircularProgressIndicator());
    if (files.isEmpty) {
      return MessageView(
        icon: Icons.search_off,
        title: 'Nenhum log encontrado',
        message: _allText
            ? 'Esta pasta não tem arquivos de texto. Rode o port uma vez para que o log seja gerado.'
            : 'Rode o port uma vez para que o log seja gerado, ou mostre todos os arquivos de texto.',
        actionLabel: _allText ? 'Atualizar' : 'Mostrar todos os .txt',
        onAction: _allText ? _reload : () => _setAllText(true),
      );
    }

    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, i) {
          final f = files[i];
          final rel = f.relativeTo(widget.port.path);
          final folder = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
          final meta = '${formatBytes(f.size)} · ${formatDate(f.modified)}'
              '${i == 0 ? ' · mais recente' : ''}';
          return ListTile(
            leading: Icon(
              Icons.description_outlined,
              color: i == 0 ? theme.colorScheme.primary : null,
            ),
            title: Text(f.name),
            subtitle: Text(folder.isEmpty ? meta : '$folder/\n$meta'),
            isThreeLine: folder.isNotEmpty,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LogViewerScreen(
                  ssh: widget.ssh,
                  port: widget.port,
                  file: f,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
