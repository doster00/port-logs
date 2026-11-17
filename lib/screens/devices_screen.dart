import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/network_scanner.dart';
import '../services/ssh_service.dart';
import 'login_dialog.dart';
import 'ports_screen.dart';

const _kLastManualHost = 'last_manual_host';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  NetworkScanner? _scanner;
  StreamSubscription<FoundDevice>? _sub;
  final _devices = <FoundDevice>[];
  List<LocalNetwork> _networks = const [];
  bool _scanning = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanner?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  static int _compareDevices(FoundDevice a, FoundDevice b) {
    if (a.likelyHandheld != b.likelyHandheld) return a.likelyHandheld ? -1 : 1;
    if (a.isSsh != b.isSsh) return a.isSsh ? -1 : 1;
    return compareIps(a.ip, b.ip);
  }

  Future<void> _startScan() async {
    _scanner?.cancel();
    await _sub?.cancel();
    final scanner = NetworkScanner();
    _scanner = scanner;
    if (!mounted) return;
    setState(() {
      _devices.clear();
      _scanning = true;
      _done = 0;
      _total = 0;
      _error = null;
    });

    List<LocalNetwork> networks;
    try {
      networks = await NetworkScanner.localNetworks();
    } catch (_) {
      networks = const [];
    }
    if (!mounted || _scanner != scanner) return;
    if (networks.isEmpty) {
      setState(() {
        _networks = const [];
        _scanning = false;
        _error = 'Nenhuma rede local encontrada. Conecte este aparelho ao Wi-Fi.';
      });
      return;
    }
    setState(() => _networks = networks);

    _sub = scanner.scan(
      networks,
      onProgress: (done, total) {
        if (!mounted || _scanner != scanner) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
    ).listen(
      (device) {
        if (!mounted || _scanner != scanner) return;
        setState(() => _devices
          ..add(device)
          ..sort(_compareDevices));
      },
      onError: (Object e) {
        if (!mounted || _scanner != scanner) return;
        setState(() => _error = 'Erro na busca: $e');
      },
      onDone: () {
        if (!mounted || _scanner != scanner) return;
        setState(() => _scanning = false);
      },
    );
  }

  Future<void> _openDevice(String host, {String? label}) async {
    final ssh = await showDialog<SshService>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LoginDialog(host: host, label: label),
    );
    if (ssh == null) return;
    if (!mounted) {
      ssh.close();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PortsScreen(ssh: ssh)),
    );
    ssh.close();
  }

  Future<void> _connectManual() async {
    String initial = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      initial = prefs.getString(_kLastManualHost) ?? '';
    } catch (_) {}
    if (!mounted) return;

    final host = await showDialog<String>(
      context: context,
      builder: (_) => _ManualHostDialog(initial: initial),
    );
    if (host == null || host.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastManualHost, host);
    } catch (_) {}
    await _openDevice(host);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Port Logs'),
        actions: [
          IconButton(
            tooltip: 'Buscar novamente',
            onPressed: _scanning ? null : _startScan,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _scanning
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _connectManual,
        icon: const Icon(Icons.edit),
        label: const Text('Digitar IP'),
      ),
      body: RefreshIndicator(
        onRefresh: _startScan,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            _buildStatus(context),
            if (_error != null) _buildError(context),
            for (final d in _devices) _buildDeviceTile(context, d),
            if (!_scanning && _devices.isEmpty && _error == null) _buildHelp(context),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final theme = Theme.of(context);
    final nets = _networks.map((n) => n.cidr).join(', ');
    final String text;
    if (_scanning) {
      text = nets.isEmpty
          ? 'Detectando a rede…'
          : 'Procurando consoles com SSH em $nets… ($_done/$_total)';
    } else if (_devices.isEmpty) {
      text = 'Nenhum dispositivo com SSH encontrado${nets.isEmpty ? '' : ' em $nets'}.';
    } else {
      text = '${_devices.length} dispositivo(s) com SSH encontrado(s). Toque para conectar.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.wifi_off, color: theme.colorScheme.onErrorContainer),
        title: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      ),
    );
  }

  Widget _buildDeviceTile(BuildContext context, FoundDevice d) {
    final details = <String>[
      if (d.hostname != null) d.ip,
      if (d.banner != null) d.banner!,
    ];
    return Card(
      child: ListTile(
        leading: Icon(d.likelyHandheld ? Icons.sports_esports : Icons.dns_outlined),
        title: Text(d.displayName),
        subtitle: Text(
          details.isEmpty ? 'SSH (porta 22)' : details.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openDevice(d.ip, label: d.hostname),
      ),
    );
  }

  Widget _buildHelp(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Não achou seu console?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '• O console e este aparelho precisam estar no mesmo Wi-Fi.\n'
              '• No ArkOS, ative o SSH em Options → Enable Remote Services.\n'
              '• Você também pode tocar em "Digitar IP" e informar o IP do console '
              '(no ArkOS, aparece em Options → Network Info).',
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualHostDialog extends StatefulWidget {
  const _ManualHostDialog({required this.initial});
  final String initial;

  @override
  State<_ManualHostDialog> createState() => _ManualHostDialogState();
}

class _ManualHostDialogState extends State<_ManualHostDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Conectar por IP'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'IP ou hostname',
          hintText: '192.168.0.50',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Continuar')),
      ],
    );
  }
}
