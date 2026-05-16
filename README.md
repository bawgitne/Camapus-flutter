# QR Origin — Absolute Coordinate System via QR Scan

## Overview

Establishes a repeatable, device-independent coordinate system by scanning a fixed QR code.
Target accuracy: < 5mm positional error between sessions and devices.

## Architecture

```
lib/
├── main.dart                    # Entry point
├── app.dart                     # MaterialApp setup
├── models/
│   ├── pose_frame.dart          # Single frame pose data
│   ├── scan_state.dart          # State machine enum
│   └── world_origin.dart        # Established origin (4x4 matrix)
├── controllers/
│   └── scan_controller.dart     # State machine + orchestration
├── pipeline/
│   ├── pose_averager.dart       # Multi-frame averaging + outlier rejection
│   └── gravity_aligner.dart     # Y-axis snap to IMU gravity
├── services/
│   └── ar_platform_service.dart # Platform channel bridge
├── screens/
│   └── scan_screen.dart         # Main scan UI
└── widgets/
    ├── angle_indicator.dart     # Perpendicularity feedback
    ├── progress_ring.dart       # Frame collection progress
    ├── debug_overlay.dart       # Real-time debug stats
    └── verification_dialog.dart # Post-scan verification prompt
```

## Setup

### Prerequisites
- Flutter SDK >= 3.16
- Android device with ARCore support (API 24+)
- Physical QR code printed at exactly 15x15cm on rigid material

### Steps

1. Install Flutter: https://docs.flutter.dev/get-started/install
2. Clone and setup:
   ```bash
   cd qr_origin
   flutter pub get
   ```
3. Place your QR reference image at `assets/qr_reference.jpg`
   - Must be the exact same image printed physically
   - Recommended: high contrast, no border artifacts
4. Connect Android device via USB (enable USB debugging)
5. Run:
   ```bash
   flutter run --debug
   ```

### Wireless Debugging (recommended for AR)
```bash
adb tcpip 5555
adb connect <device-ip>:5555
# Disconnect USB cable
flutter run --debug
```

## How It Works

### Scan Flow State Machine
```
SCANNING → COLLECTING → AVERAGING → VERIFYING → LOCKED
    ↑                                     |
    └─────────── (reject) ────────────────┘
```

### Key Algorithms

1. **Angle Gate**: Only accepts frames where camera is within ±20° of perpendicular to QR
2. **Multi-frame Averaging**: Collects 30 frames, rejects outliers (>1σ reproj error), averages via iterative SLERP
3. **Gravity Alignment**: Snaps Y-axis to IMU gravity, preserving heading from QR detection
4. **Verification**: Projects known test point, user confirms alignment

## Debug Tools

- Toggle debug overlay with 🐛 button (bottom-left)
- Shows: angle score, reprojection error, frame counts, state
- Shake device to export frame log as JSON (TODO)

## Physical Setup Requirements

- QR printed on rigid, flat material (acrylic/aluminum recommended)
- Fixed mount — no vibration
- Uniform lighting — no shadows crossing QR surface
- Minimum size: 15×15cm
- Measure actual printed size with calipers and update `qrPhysicalSize` in code
