import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Uma rede IPv4 local (assumida /24) em que o aparelho está conectado.
class LocalNetwork {
  const LocalNetwork({
    required this.interfaceName,
    required this.address,
    required this.prefix,
  });

  final String interfaceName;
  final String address;

  /// Três primeiros octetos, ex.: "192.168.0".
  final String prefix;

  String get cidr => '$prefix.0/24';
}

/// Um host com a porta SSH aberta.
class FoundDevice {
  const FoundDevice({required this.ip, this.hostname, this.banner});

  final String ip;
  final String? hostname;
  final String? banner;

  String get displayName => hostname ?? ip;

  bool get isSsh => banner?.startsWith('SSH-') ?? false;

  /// Heurística pelo hostname para destacar consoles portáteis.
  bool get likelyHandheld {
    final h = (hostname ?? '').toLowerCase();
    if (h.isEmpty) return false;
    return _handheldHints.any(h.contains);
  }
}

const _handheldHints = [
  'rg', 'ark', 'anbernic', 'r36', 'r35', 'rocknix', 'jelos', 'muos', 'knulli',
  'batocera', 'retro', 'odroid', 'powkiddy', 'miyoo', 'trimui', 'magicx',
  'gameforce', 'handheld', 'game', 'x55', 'rgb',
];

/// Interfaces que não são a rede local (dados móveis, VPN, VMs...).
const _ignoredInterfacePrefixes = [
  'rmnet', 'ccmni', 'pdp', 'tun', 'dummy', 'v4-', 'clat', 'ppp', 'ipsec',
  'docker', 'veth', 'br-', 'virbr', 'vethernet', 'vmnet', 'vboxnet',
  'tailscale', 'zt', 'utun', 'awdl', 'llw', 'wg',
];

int compareIps(String a, String b) {
  final pa = a.split('.').map(int.tryParse).toList();
  final pb = b.split('.').map(int.tryParse).toList();
  for (var i = 0; i < 4; i++) {
    final x = (i < pa.length ? pa[i] : null) ?? 0;
    final y = (i < pb.length ? pb[i] : null) ?? 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class NetworkScanner {
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  static Future<List<LocalNetwork>> localNetworks() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final result = <LocalNetwork>[];
    final seen = <String>{};
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (_ignoredInterfacePrefixes.any(name.startsWith)) continue;
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('169.254.') || ip.startsWith('127.')) continue;
        final parts = ip.split('.');
        if (parts.length != 4) continue;
        final prefix = parts.take(3).join('.');
        if (!seen.add(prefix)) continue;
        result.add(LocalNetwork(
          interfaceName: iface.name,
          address: ip,
          prefix: prefix,
        ));
      }
    }
    return result;
  }

  /// Varre as redes procurando a porta [port] aberta. Emite cada host
  /// encontrado assim que ele responde.
  Stream<FoundDevice> scan(
    List<LocalNetwork> networks, {
    int port = 22,
    Duration connectTimeout = const Duration(milliseconds: 700),
    int concurrency = 48,
    void Function(int done, int total)? onProgress,
  }) {
    final controller = StreamController<FoundDevice>();

    Future<void> run() async {
      final targets = <String>[
        for (final net in networks)
          for (var i = 1; i < 255; i++)
            if ('${net.prefix}.$i' != net.address) '${net.prefix}.$i',
      ];
      var next = 0;
      var done = 0;
      onProgress?.call(0, targets.length);

      Future<void> worker() async {
        while (!_cancelled && next < targets.length) {
          final ip = targets[next++];
          final device = await _probe(ip, port, connectTimeout);
          done++;
          if (_cancelled) return;
          onProgress?.call(done, targets.length);
          if (device != null && !controller.isClosed) controller.add(device);
        }
      }

      try {
        await Future.wait(List.generate(concurrency, (_) => worker()));
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }

    run();
    return controller.stream;
  }

  Future<FoundDevice?> _probe(String ip, int port, Duration timeout) async {
    Socket socket;
    try {
      socket = await Socket.connect(ip, port, timeout: timeout);
    } catch (_) {
      return null;
    }

    String? banner;
    try {
      final data = await socket.first.timeout(const Duration(milliseconds: 1500));
      banner = utf8.decode(data, allowMalformed: true).split('\n').first.trim();
      if (banner.isEmpty) banner = null;
    } catch (_) {
      // Sem banner: ainda pode ser útil, mantemos o host.
    } finally {
      socket.destroy();
    }

    String? hostname;
    try {
      final rev = await InternetAddress(ip).reverse().timeout(const Duration(seconds: 2));
      if (rev.host.isNotEmpty && rev.host != ip) hostname = rev.host;
    } catch (_) {}

    return FoundDevice(ip: ip, hostname: hostname, banner: banner);
  }
}
