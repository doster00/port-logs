<p align="center">
  <img src="assets/icon/icon.png" width="128" alt="Port Logs">
</p>

<h1 align="center">Port Logs</h1>

<p align="center">
  Pegue o log de um port no seu portátil Linux e mande para o dev, direto do celular.
</p>

Quando um port dá problema, os devs pedem o log. Este app encontra o console na rede
pelo SSH, mostra os logs de cada port e abre o menu de compartilhar do Android
(WhatsApp, Discord, Telegram, e-mail…). Não precisa de terminal nem de cabo.

Testado com ArkOS. Também deve funcionar em ROCKNIX, Knulli, muOS e outros sistemas
com SSH e pasta `ports`.

## Download

Baixe o APK mais recente em **[Releases](../../releases/latest)** e instale no celular.
Talvez o Android peça para permitir a instalação de apps desconhecidos.

## Como usar

1. No console, ative o SSH. No ArkOS: **Options → Enable Remote Services**.
2. Deixe o console e o celular no mesmo Wi-Fi.
3. Abra o Port Logs e toque no console que aparecer na lista. Se ele não aparecer, toque em
   **Digitar IP** e use o IP mostrado em **Options → Network Info**.
4. Entre com usuário e senha. O padrão do ArkOS é `ark` / `ark`.
5. Escolha o port e depois o arquivo de log.
6. Toque em **compartilhar**. O arquivo vai completo, com as informações do console no começo
   (modelo, firmware, kernel, versão do PortMaster…). Dá para desligar isso no menu ⋮.

## O que ele faz

- **Encontra os consoles:** varre a rede local (/24) procurando a porta 22. Nomes conhecidos
  (rg, ark, rocknix, r36…) aparecem primeiro.
- **Lista os ports:** pastas em `/roms/ports`, `/roms2/ports`, `/storage/roms/ports`,
  `/userdata/roms/ports`, `/mnt/mmc/ports` e `/mnt/sdcard/ports`.
- **Acha os logs:** `*.log`, `*.log.N` e `.txt` com `log`, `report`, `crash`, `error` ou
  `debug` no nome, do mais recente para o mais antigo. Uma chave mostra todos os arquivos de texto.
- **Mostra sem editar:** erros em vermelho, avisos em laranja, quebra de linha opcional.
  Em arquivos acima de 1 MB, a tela mostra só o final, mas o arquivo é compartilhado inteiro.

No console, o app só roda `find`, `stat`, `cat`, `tail` e comandos de leitura de informações
do sistema. Ele nunca altera nada.

## Compilar

Requisitos: [Flutter](https://docs.flutter.dev/get-started/install) 3.24 ou mais novo,
Android SDK e JDK 17.

```sh
flutter pub get
flutter test
flutter run                   # celular conectado com depuração USB
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

O APK de release é assinado com a chave indicada em `android/key.properties`, que não vai
para o git. Sem esse arquivo, o build usa a chave de debug:

```properties
storePassword=...
keyPassword=...
keyAlias=...
storeFile=C:/caminho/para/release.jks
```

Para gerar os ícones de novo a partir de `assets/icon/`, rode `dart run flutter_launcher_icons`.

## Estrutura

```
lib/
  main.dart
  services/network_scanner.dart   busca de hosts com a porta 22 aberta
  services/ssh_service.dart       SSH (dartssh2): ports, logs, leitura, info do console
  screens/devices_screen.dart     lista de consoles e entrada manual de IP
  screens/login_dialog.dart       usuário e senha
  screens/ports_screen.dart       lista de ports com busca
  screens/logs_screen.dart        arquivos de log do port
  screens/log_viewer_screen.dart  visualizador, copiar e compartilhar
```

## Licença

[MIT](LICENSE)
