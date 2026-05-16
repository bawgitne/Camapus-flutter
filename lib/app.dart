import 'package:flutter/material.dart';
import 'package:qr_origin/screens/ar_axes_screen.dart';

class QrOriginApp extends StatelessWidget {
  const QrOriginApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QR Origin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ArAxesScreen(),
    );
  }
}
