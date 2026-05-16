import 'package:flutter/material.dart';
import 'package:qr_origin/app.dart';
import 'package:qr_origin/services/service_locator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize persistent storage and services
  await ServiceLocator.initialize();

  runApp(const QrOriginApp());
}
