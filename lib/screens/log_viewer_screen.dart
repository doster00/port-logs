import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ssh_service.dart';
import '../utils/format.dart';
import '../widgets/state_views.dart';

final _ansiEscape = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

const _errorWords = [
  'error', 'fatal', 'exception', 'segmentation fault', 'segfault', 'failed',
  'traceback', 'cannot ', "can't ", 'not found', 'no such file',
  'core dumped', 'panic', 'aborted',
];

/// Visualizador somente leitura, com opção de copiar e compartilhar.
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({
    super.key,
    required this.ssh,
    required this.port,
    required this.file,
  });

  final SshService ssh;
  final PortEntry port;
  final LogFile file;

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _scroll = ScrollController();
  bool _loading = true;
  String? _error;
  List<String> _lines = const [];
  int _maxLineLength = 0;
  Uint8List? _fullBytes;
  bool _truncated = false;
  bool _wrap = true;
  bool _busy = false;
  bool _includeInfo = true;

  static const _kIncludeInfo = 'include_device_info';

  bool get _isDesktop => Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _fetch();
    _loadPrefs();
    // Já vai buscando as informações do console em segundo plano.
    widget.ssh.deviceInfo().ignore();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(_kIncludeInfo);
      if (v != null && mounted) setState(() => _includeInfo = v);
    } catch (_) {}
  }

  Future<void> _setIncludeInfo(bool value) async {
    setState(() => _includeInfo = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kIncludeInfo, value);
    } catch (_) {}
  }

  /// Cabeçalho com dados do console e do arquivo, para quem vai ler o log.
  Future<String> _buildHeader() async {
    List<MapEntry<String, String>> info;
    try {
      info = await widget.ssh.deviceInfo();
    } catch (_) {
      info = const [];
    }
    final f = widget.file;
    final b = StringBuffer()
      ..writeln('===== Informações do console (Port Logs) =====');
    for (final e in info) {
      b.writeln('${e.key}: ${e.value}');
    }
    b
      ..writeln('Port: ${widget.port.name} (${widget.port.path})')
      ..writeln('Arquivo: ${f.relativeTo(widget.port.path)} '
          '(${formatBytes(f.size)}, modificado em ${formatDate(f.modified)})')
      ..writeln('Gerado em: ${formatDate(DateTime.now())}')
      ..writeln('===== Log =====');
    return b.toString();
  }

  Future<void> _showDeviceInfo() async {
    final header = _buildHeader();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Informações do console'),
        content: FutureBuilder<String>(
          future: header,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return SingleChildScrollView(
              child: SelectableText(
                snap.data!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
                  fontSize: 12,
                ),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final file = widget.file;
    final truncated = file.size > SshService.viewerMaxBytes;
    try {
      final bytes = await widget.ssh.readBytes(
        file.path,
        tailBytes: truncated ? SshService.viewerMaxBytes : null,
      );
      var text = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .replaceAll('\t', '    ')
          .replaceAll(_ansiEscape, '');
      if (truncated) {
        // A primeira linha provavelmente veio cortada pela metade.
        final nl = text.indexOf('\n');
        if (nl >= 0) text = text.substring(nl + 1);
      }
      final lines = text.split('\n');
      if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
      var maxLen = 0;
      for (final l in lines) {
        if (l.length > maxLen) maxLen = l.length;
      }
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _maxLineLength = maxLen;
        _truncated = truncated;
        _fullBytes = truncated ? null : bytes;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
  }

  // ---------- exportar ----------

  Future<Uint8List> _bytesForExport() async {
    final size = widget.file.size;
    final log = _fullBytes ??
        await widget.ssh.readBytes(
          widget.file.path,
          tailBytes: size > SshService.shareMaxBytes ? SshService.shareMaxBytes : null,
        );
    if (!_includeInfo) return log;
    final out = BytesBuilder(copy: false)
      ..add(utf8.encode(await _buildHeader()))
      ..add(log);
    return out.takeBytes();
  }

  String _exportFileName() {
    final rel = widget.file.relativeTo(widget.port.path).replaceAll('/', '_');
    var name = '${widget.port.name}_$rel'.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    if (!RegExp(r'\.(txt|log)$', caseSensitive: false).hasMatch(name)) {
      name = '$name.txt';
    }
    return name;
  }

  Future<File> _writeTo(Directory dir) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${_exportFileName()}');
    await file.writeAsBytes(await _bytesForExport(), flush: true);
    return file;
  }

  Future<void> _share(Rect? origin) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_isDesktop) {
        final downloads = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final file = await _writeTo(downloads);
        _snack('Salvo em ${file.path}');
        return;
      }
      final tmp = await getTemporaryDirectory();
      final file = await _writeTo(Directory('${tmp.path}${Platform.pathSeparator}port_logs'));
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Log do port ${widget.port.name}',
        text: 'Log do port ${widget.port.name}: '
            '${widget.file.relativeTo(widget.port.path)}',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      _snack('Não foi possível compartilhar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final header = _includeInfo ? await _buildHeader() : '';
    await Clipboard.setData(ClipboardData(text: header + _lines.join('\n')));
    _snack(_truncated
        ? 'Copiado (só o final do arquivo). Use compartilhar para enviar o arquivo completo.'
        : 'Log copiado para a área de transferência.');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    // Com quebra de linha as alturas são estimadas; reajusta no próximo frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToStart() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null;
    return Scaffold(
      appBar: AppBar(
        title: TwoLineTitle(
          widget.file.name,
          '${widget.port.name} · ${formatBytes(widget.file.size)}',
        ),
        actions: [
          IconButton(
            tooltip: _wrap ? 'Não quebrar linhas' : 'Quebrar linhas',
            onPressed: ready ? () => setState(() => _wrap = !_wrap) : null,
            icon: Icon(_wrap ? Icons.wrap_text : Icons.short_text),
          ),
          IconButton(
            tooltip: 'Copiar',
            onPressed: ready ? _copy : null,
            icon: const Icon(Icons.copy),
          ),
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: _isDesktop ? 'Salvar em Downloads' : 'Compartilhar',
              onPressed: ready && !_busy
                  ? () {
                      final box = buttonContext.findRenderObject() as RenderBox?;
                      final origin = box == null
                          ? null
                          : box.localToGlobal(Offset.zero) & box.size;
                      _share(origin);
                    }
                  : null,
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_isDesktop ? Icons.download : Icons.share),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'include') _setIncludeInfo(!_includeInfo);
              if (v == 'info') _showDeviceInfo();
            },
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: 'include',
                checked: _includeInfo,
                child: const Text('Incluir informações do console ao compartilhar'),
              ),
              const PopupMenuItem(
                value: 'info',
                child: Text('Ver informações do console'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: ready && _lines.length > 40
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'top',
                  tooltip: 'Início',
                  onPressed: _jumpToStart,
                  child: const Icon(Icons.vertical_align_top),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'end',
                  tooltip: 'Fim',
                  onPressed: _jumpToEnd,
                  child: const Icon(Icons.vertical_align_bottom),
                ),
              ],
            )
          : null,
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return MessageView(
        icon: Icons.error_outline,
        title: 'Não foi possível abrir o arquivo',
        message: _error,
        actionLabel: 'Tentar de novo',
        onAction: _reload,
        isError: true,
      );
    }
    if (_lines.length == 1 && _lines.first.trim().isEmpty) {
      return const MessageView(icon: Icons.notes, title: 'Arquivo vazio');
    }

    final theme = Theme.of(context);
    return Column(
      children: [
        if (_truncated)
          Container(
            width: double.infinity,
            color: theme.colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Arquivo grande: mostrando só o último 1 MB. '
                    'Ao compartilhar, o arquivo vai completo.',
                    style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
        Expanded(child: _buildLines(theme)),
      ],
    );
  }

  Color? _lineColor(String line, ThemeData theme) {
    final l = line.toLowerCase();
    if (_errorWords.any(l.contains)) return theme.colorScheme.error;
    if (l.contains('warn')) {
      return theme.brightness == Brightness.dark
          ? Colors.orange.shade300
          : Colors.orange.shade800;
    }
    return null;
  }

  Widget _buildLines(ThemeData theme) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
      fontSize: 12.5,
      height: 1.35,
      color: theme.colorScheme.onSurface,
    );

    Widget list() => Scrollbar(
          controller: _scroll,
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 120),
            itemCount: _lines.length,
            itemBuilder: (context, i) {
              final line = _lines[i];
              return Text(
                line.isEmpty ? ' ' : line,
                softWrap: _wrap,
                overflow: _wrap ? null : TextOverflow.clip,
                style: style.copyWith(color: _lineColor(line, theme)),
              );
            },
          ),
        );

    if (_wrap) return SelectionArea(child: list());

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.min(_maxLineLength, 4000) * 7.8 + 24;
        final width = math.max(constraints.maxWidth, contentWidth);
        return SelectionArea(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: width, height: constraints.maxHeight, child: list()),
          ),
        );
      },
    );
  }
}
