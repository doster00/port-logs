import 'package:flutter/material.dart';

import 'screens/devices_screen.dart';

void main() => runApp(const PortLogsApp());

class PortLogsApp extends StatelessWidget {
  const PortLogsApp({super.key});

  static const _seed = Color(0xFF7C4DFF);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Port Logs',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const DevicesScreen(),
    );
  }
}
