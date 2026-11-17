import 'package:flutter/material.dart';

import '../services/ssh_service.dart';
import '../widgets/state_views.dart';
import 'logs_screen.dart';

class PortsScreen extends StatefulWidget {
  const PortsScreen({super.key, required this.ssh});

  final SshService ssh;

  @override
  State<PortsScreen> createState() => _PortsScreenState();
}

class _PortsScreenState extends State<PortsScreen> {
  List<PortEntry>? _ports;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final ports = await widget.ssh.listPorts();
      if (mounted) setState(() => _ports = ports);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _reload() {
    setState(() {
      _ports = null;
      _error = null;
    });
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final ssh = widget.ssh;
    return Scaffold(
      appBar: AppBar(
        title: TwoLineTitle('Ports', '${ssh.username}@${ssh.host}'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: _ports == null && _error == null ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return MessageView(
        icon: Icons.error_outline,
        title: 'Não foi possível listar os ports',
        message: _error,
        actionLabel: 'Tentar de novo',
        onAction: _reload,
        isError: true,
      );
    }
    final ports = _ports;
    if (ports == null) return const Center(child: CircularProgressIndicator());
    if (ports.isEmpty) {
      return MessageView(
        icon: Icons.folder_off_outlined,
        title: 'Nenhum port encontrado',
        message: 'Procurei em:\n${SshService.portRoots.join('\n')}',
        actionLabel: 'Atualizar',
        onAction: _reload,
      );
    }

    final multipleRoots = ports.map((p) => p.root).toSet().length > 1;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? ports
        : ports.where((p) => p.name.toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Buscar entre ${ports.length} ports',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _fetch,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final port = filtered[i];
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(port.name),
                  subtitle: multipleRoots ? Text(port.root) : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LogsScreen(ssh: widget.ssh, port: port),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
