import 'package:flutter_test/flutter_test.dart';
import 'package:port_logs/services/network_scanner.dart';
import 'package:port_logs/services/ssh_service.dart';

void main() {
  test('shQuote escapa aspas simples', () {
    expect(shQuote('Stardew Valley'), "'Stardew Valley'");
    expect(shQuote("it's"), r"'it'\''s'");
  });

  test('parseStatOutput lê mtime|tamanho|caminho e ordena por data', () {
    const out = '1700000000|120|/roms/ports/Game/log.txt\n'
        '1700000100|5|/roms/ports/Game/sub dir/a|b.log\n'
        'lixo sem separador\n'
        '1700000000|120|/roms/ports/Game/log.txt\n';
    final files = parseStatOutput(out);
    expect(files, hasLength(2));
    expect(files.first.path, '/roms/ports/Game/sub dir/a|b.log');
    expect(files.first.relativeTo('/roms/ports/Game'), 'sub dir/a|b.log');
    expect(files.first.name, 'a|b.log');
    expect(files.last.size, 120);
  });

  test('parsePortList remove duplicados e ordena por nome', () {
    final ports = parsePortList('/roms/ports/zelda\n/roms/ports/Abc\n\n/roms/ports/zelda\n');
    expect(ports.map((p) => p.name), ['Abc', 'zelda']);
    expect(ports.first.root, '/roms/ports');
  });

  test('parseDeviceInfo traduz chaves e ignora repetidos/desconhecidos', () {
    const out = 'device=RG353V\n'
        'cfw=ArkOS 2.0 (08242024)\n'
        'hostname=rg353v\n'
        'portmaster=8.5.1\n'
        'portmaster=8.4.0\n'
        'disk=/roms: 20G livres de 58G\n'
        'disk=/roms: 20G livres de 58G\n'
        'xyz=ignorar\n'
        'kernel=\n';
    final info = parseDeviceInfo(out);
    expect(info.map((e) => '${e.key}: ${e.value}'), [
      'Dispositivo: RG353V',
      'Firmware: ArkOS 2.0 (08242024)',
      'Hostname: rg353v',
      'PortMaster: 8.5.1',
      'Espaço: /roms: 20G livres de 58G',
    ]);
  });

  test('compareIps compara numericamente', () {
    expect(compareIps('192.168.0.9', '192.168.0.10'), lessThan(0));
    expect(compareIps('10.0.0.1', '10.0.0.1'), 0);
  });
}
