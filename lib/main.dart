import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/server_home_page.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      PlatformDispatcher.instance.onError = (error, stack) {
        if (_isClosedSmbSinkError(error)) {
          debugPrint('Ignored closed SMB socket error: $error');
          return true;
        }
        return false;
      };
      MediaKit.ensureInitialized();
      runApp(const NasPlayerApp());
    },
    (error, stack) {
      if (_isClosedSmbSinkError(error)) {
        debugPrint('Ignored closed SMB socket error: $error');
        return;
      }
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

bool _isClosedSmbSinkError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('streamsink is closed');
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
