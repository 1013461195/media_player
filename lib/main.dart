import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/server_home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const NasPlayerApp());
}

class NasPlayerApp extends StatelessWidget {
  const NasPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff0f766e),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
        listTileTheme:
            const ListTileThemeData(contentPadding: EdgeInsets.zero),
      ),
      home: const ServerHomePage(),
    );
  }
}
