import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class SshConnectError implements Exception {
  SshConnectError(this.message);
  final String message;
  @override
  String toString() => message;
}

class SshCommandError implements Exception {
  SshCommandError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uma pasta de port, ex.: /roms/ports/Stardew Valley
class PortEntry {
  const PortEntry(this.path);
  final String path;

  String get name => path.substring(path.lastIndexOf('/') + 1);
  String get root => path.substring(0, path.lastIndexOf('/'));
}

class LogFile {
  const LogFile({required this.path, required this.size, required this.modified});

  final String path;
  final int size;
  final DateTime modified;

  String get name => path.substring(path.lastIndexOf('/') + 1);

  String relativeTo(String base) =>
      path.startsWith('$base/') ? path.substring(base.length + 1) : path;
}

/// Coloca [s] entre aspas simples para uso seguro no shell remoto.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Interpreta a saída de `stat -c '%Y|%s|%n'` (mtime|tamanho|caminho).
/// Ordena do mais recente para o mais antigo.
List<LogFile> parseStatOutput(String out) {
  final files = <LogFile>[];
  final seen = <String>{};
  for (final line in const LineSplitter().convert(out)) {
    final a = line.indexOf('|');
    if (a < 0) continue;
    final b = line.indexOf('|', a + 1);
    if (b < 0) continue;
    final mtime = int.tryParse(line.substring(0, a));
    final size = int.tryParse(line.substring(a + 1, b));
    final path = line.substring(b + 1);
    if (mtime == null || size == null || path.isEmpty || !seen.add(path)) continue;
    files.add(LogFile(
      path: path,
      size: size,
      modified: DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
    ));
  }
  files.sort((x, y) => y.modified.compareTo(x.modified));
  return files;
}

List<PortEntry> parsePortList(String out) {
  final seen = <String>{};
  final ports = <PortEntry>[
    for (final line in const LineSplitter().convert(out))
      if (line.trim().isNotEmpty && seen.add(line)) PortEntry(line),
  ];
  ports.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return ports;
}

// Nomes com "log/report/crash/error/debug" em .txt, ou qualquer .log / .log.N
const _logFilter =
    r"\( -iname '*.log' -o -iname '*.log.[0-9]*' -o \( -iname '*.txt' \( -iname '*log*' -o -iname '*report*' -o -iname '*crash*' -o -iname '*error*' -o -iname '*debug*' \) \) \)";

const _allTextFilter =
    r"\( -iname '*.txt' -o -iname '*.log' -o -iname '*.log.[0-9]*' -o -iname '*.out' -o -iname '*.err' \)";

const _listPortsScript =
    r'for d in __ROOTS__; do [ -d "$d" ] || continue; for p in "$d"/*/; do [ -d "$p" ] && printf "%s\n" "${p%/}"; done; done; true';

// Coleta dados do console em linhas "chave=valor". Tudo é opcional:
// o que não existir no sistema simplesmente não aparece.
const _deviceInfoScript = r'''
[ -f "$HOME/.config/.DEVICE" ] && echo "device=$(head -n1 "$HOME/.config/.DEVICE")"
m=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null); [ -n "$m" ] && echo "model=$m"
t=$(grep -m1 '^title=' /usr/share/plymouth/themes/text.plymouth 2>/dev/null | cut -d= -f2-); [ -n "$t" ] && echo "cfw=$t"
if [ -r /etc/os-release ]; then . /etc/os-release; [ -n "$PRETTY_NAME" ] && echo "os=$PRETTY_NAME"; fi
echo "hostname=$(hostname 2>/dev/null)"
echo "kernel=$(uname -srm 2>/dev/null)"
[ -r /sys/class/graphics/fb0/virtual_size ] && echo "screen=$(tr ',' 'x' < /sys/class/graphics/fb0/virtual_size)"
free -m 2>/dev/null | awk '/^Mem:/{print "memory="$3" MB usados de "$2" MB"}'
for d in __ROOTS__; do [ -f "$d/PortMaster/version" ] && echo "portmaster=$(head -n1 "$d/PortMaster/version")"; done
for d in __ROOTS__; do [ -d "$d" ] && df -h "$d" 2>/dev/null | awk 'NR>1{print "disk="$NF": "$(NF-2)" livres de "$(NF-4)}'; done
true
''';

const _deviceInfoLabels = {
  'device': 'Dispositivo',
  'model': 'Modelo',
  'cfw': 'Firmware',
  'os': 'Sistema',
  'hostname': 'Hostname',
  'kernel': 'Kernel',
  'screen': 'Tela',
  'memory': 'Memória',
  'portmaster': 'PortMaster',
  'disk': 'Espaço',
};

/// Converte a saída do script de informações em pares (rótulo, valor),
/// na ordem em que aparecem, sem repetições.
List<MapEntry<String, String>> parseDeviceInfo(String out) {
  final result = <MapEntry<String, String>>[];
  final seen = <String>{};
  for (final line in const LineSplitter().convert(out)) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final label = _deviceInfoLabels[line.substring(0, eq)];
    final value = line.substring(eq + 1).trim();
    if (label == null || value.isEmpty || !seen.add('$label|$value')) continue;
    // Só um valor de PortMaster, mesmo que haja dois cartões.
    if (label == 'PortMaster' && result.any((e) => e.key == label)) continue;
    result.add(MapEntry(label, value));
  }
  return result;
}

class _RawResult {
  _RawResult(this.stdout, this.stderr, this.exitCode);
  final Uint8List stdout;
  final String stderr;
  final int? exitCode;
}

class SshService {
  SshService._(this.host, this.port, this.username, this._client);

  final String host;
  final int port;
  final String username;
  final SSHClient _client;

  /// Onde os ports costumam ficar (ArkOS, 2º cartão, ROCKNIX, Knulli, muOS...).
  static const portRoots = [
    '/roms/ports',
    '/roms2/ports',
    '/storage/roms/ports',
    '/userdata/roms/ports',
    '/mnt/mmc/ports',
    '/mnt/sdcard/ports',
  ];

  /// Quanto do final do arquivo é carregado no visualizador.
  static const viewerMaxBytes = 1024 * 1024;

  /// Limite para o arquivo compartilhado.
  static const shareMaxBytes = 50 * 1024 * 1024;

  bool get isClosed => _client.isClosed;

  static Future<SshService> connect({
    required String host,
    int port = 22,
    required String username,
    required String password,
  }) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 8));
    } on SocketException catch (e) {
      throw SshConnectError(
        'Não foi possível conectar em $host:$port. Verifique se o console está '
        'ligado, no mesmo Wi-Fi e com o SSH ativado.\n(${e.message})',
      );
    } on TimeoutException {
      throw SshConnectError('Tempo esgotado ao conectar em $host:$port.');
    } catch (e) {
      throw SshConnectError('Não foi possível conectar em $host:$port: $e');
    }

    final client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
      onUserInfoRequest: (request) => request.prompts.map((_) => password).toList(),
    );

    try {
      await client.authenticated.timeout(const Duration(seconds: 20));
    } on SSHAuthFailError {
      client.close();
      throw SshConnectError('Usuário ou senha incorretos.');
    } on TimeoutException {
      client.close();
      throw SshConnectError('O console não respondeu à autenticação.');
    } catch (e) {
      client.close();
      throw SshConnectError('Falha ao autenticar: $e');
    }

    return SshService._(host, port, username, client);
  }

  Future<_RawResult> _exec(
    String command, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final session = await _client.execute(command);
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    try {
      await Future.wait([
        session.stdout.forEach(out.add),
        session.stderr.forEach(err.add),
        session.done,
      ]).timeout(timeout);
    } on TimeoutException {
      session.close();
      throw SshCommandError('O console demorou demais para responder.');
    }
    return _RawResult(
      out.takeBytes(),
      utf8.decode(err.takeBytes(), allowMalformed: true),
      session.exitCode,
    );
  }

  Future<List<PortEntry>> listPorts() async {
    final roots = portRoots.map(shQuote).join(' ');
    final r = await _exec(_listPortsScript.replaceFirst('__ROOTS__', roots));
    return parsePortList(utf8.decode(r.stdout, allowMalformed: true));
  }

  /// Procura arquivos com cara de log dentro de [dir].
  /// Com [allText], lista qualquer arquivo de texto comum.
  Future<List<LogFile>> findLogs(String dir, {bool allText = false}) async {
    final filter = allText ? _allTextFilter : _logFilter;
    final cmd = 'find -L ${shQuote(dir)} -maxdepth 6 -type f $filter '
        "-exec stat -c '%Y|%s|%n' {} + 2>/dev/null";
    final r = await _exec(cmd, timeout: const Duration(seconds: 90));
    return parseStatOutput(utf8.decode(r.stdout, allowMalformed: true));
  }

  /// Lê o arquivo inteiro, ou só os últimos [tailBytes] bytes.
  Future<Uint8List> readBytes(String path, {int? tailBytes}) async {
    final q = shQuote(path);
    final cmd = tailBytes == null ? 'cat $q' : 'tail -c $tailBytes $q';
    final r = await _exec(cmd, timeout: const Duration(seconds: 120));
    if ((r.exitCode ?? 0) != 0) {
      final msg = r.stderr.trim();
      throw SshCommandError(msg.isEmpty ? 'Não foi possível ler o arquivo.' : msg);
    }
    return r.stdout;
  }

  Future<List<MapEntry<String, String>>>? _deviceInfo;

  /// Informações do console (modelo, firmware, kernel...). Fica em cache
  /// durante a conexão; se falhar, tenta de novo na próxima chamada.
  Future<List<MapEntry<String, String>>> deviceInfo() {
    return _deviceInfo ??= () async {
      try {
        final roots = portRoots.map(shQuote).join(' ');
        final r = await _exec(
          _deviceInfoScript.replaceAll('__ROOTS__', roots),
          timeout: const Duration(seconds: 20),
        );
        return parseDeviceInfo(utf8.decode(r.stdout, allowMalformed: true));
      } catch (_) {
        _deviceInfo = null;
        rethrow;
      }
    }();
  }

  void close() {
    if (!_client.isClosed) _client.close();
  }
}
