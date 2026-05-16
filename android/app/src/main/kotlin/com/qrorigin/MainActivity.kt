package com.qrorigin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register ARCore PlatformView with Hybrid Composition
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "arcore_axes_view",
            ArCoreViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
}
