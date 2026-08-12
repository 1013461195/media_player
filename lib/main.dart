import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/server_home_page.dart';
import 'widgets/common.dart';

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
          seedColor: appAccent,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: appBackground,
        useMaterial3: true,
        fontFamilyFallback: const [
          'SF Pro Text',
          'PingFang SC',
          'Helvetica Neue',
        ],
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Color(0xfff7f7f9),
        ),
        listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.zero),
        appBarTheme: const AppBarTheme(
          backgroundColor: appBackground,
          foregroundColor: appTextPrimary,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const ServerHomePage(),
    );
  }
}
