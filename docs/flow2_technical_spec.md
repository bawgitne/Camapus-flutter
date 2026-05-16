# Flow 2 — Duy trì Hệ trục Tọa độ khi không nhìn thấy QR

## Mục tiêu

- Drift < 10cm sau 60 giây di chuyển bình thường
- Drift < 30cm sau 3 phút
- Không bao giờ cho user thông tin sai — freeze nếu không đủ tin cậy

---

## Tổng quan Pipeline

```
Origin Locked (Flow 1)
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  Mỗi frame (30fps):                                    │
│                                                         │
│  1. ARCore VIO duy trì world frame                     │
│  2. Check QR visible? → correction (ground truth)      │
│  3. Check env anchors tracking? → correction           │
│  4. Apply smooth correction (lerp/slerp)               │
│  5. Update confidence score                            │
│  6. Dead reckoning check (freeze nếu > 90s)           │
│  7. Render axes + nodes tại lockedOriginMatrix         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 1. VIO Delta Tracking (Phase 1)

### Nguyên lý
ARCore chạy Visual-Inertial Odometry (VIO) liên tục:
- Fuse camera images + IMU (accelerometer + gyroscope)
- Duy trì world coordinate frame ổn định
- Drift rate: ~0.5–1% theo quãng đường di chuyển

### Cách sử dụng
Không tự implement VIO — dùng trực tiếp ARCore world frame:

```
// Khi QR detected lần đầu:
lockedOriginMatrix = image.centerPose.toMatrix()  // lưu 4x4 matrix

// Mỗi frame sau đó (dù QR không visible):
render(axes, lockedOriginMatrix)  // ARCore VIO giữ matrix đúng vị trí
```

### Tại sao hoạt động
- ARCore world frame là **persistent** trong 1 session
- `lockedOriginMatrix` là tọa độ cố định trong world frame
- VIO tracking camera movement → camera di chuyển, origin đứng yên
- Không cần tính `deltaFromVIO` thủ công — ARCore đã handle

### Biến số
- `lockedOriginMatrix: FloatArray(16)` — 4×4 column-major
- `lockedOriginPose: Pose` — ARCore Pose object (cho compose operations)
- `originLocked: Boolean` — flag đã lock chưa

### Camera Relative Position (liên tục)
```kotlin
// Tính vị trí camera trong hệ tọa độ QR origin:
val inversePose = lockedOriginPose.inverse()
val cameraInQrSpace = inversePose.compose(camera.pose)
relativeX = cameraInQrSpace.tx()  // meters
relativeY = cameraInQrSpace.ty()
relativeZ = cameraInQrSpace.tz()
```

---

## 2. Environmental Anchors (Phase 2)

### Nguyên lý
Tạo anchors tại các vị trí vật lý gần QR ngay sau khi lock. ARCore gắn anchors vào feature points thật (góc tường, vạch sàn, texture). Khi VIO drift, anchors vẫn "neo" vào thế giới thật → dùng để detect và correct drift.

### Vị trí đặt anchors (relative to QR center)
```
Anchor 0: (+0.5m, 0, 0)     — phải
Anchor 1: (-0.5m, 0, 0)     — trái
Anchor 2: (0, 0, +0.5m)     — trước
Anchor 3: (0, 0, -0.5m)     — sau
Anchor 4: (0, +0.3m, 0)     — trên
```

### Tạo anchor
```kotlin
val anchorPose = qrPose.compose(Pose.makeTranslation(offsetX, offsetY, offsetZ))
val anchor = session.createAnchor(anchorPose)
```

### Lưu relationship
Mỗi anchor lưu cách tính ngược về origin:
```kotlin
// relativeToOrigin = anchorPose⁻¹ × qrPose
val relMatrix = anchorPose.inverse().compose(qrPose).toMatrix()
```

### Khi anchor re-observed
```kotlin
// Tính origin position từ anchor:
observedOriginMatrix = anchorWorldMatrix × relativeToOrigin
```

### Biến số
- `envAnchors: List<EnvironmentalAnchor>` — max 5
- `EnvironmentalAnchor.anchor: Anchor` — ARCore anchor object
- `EnvironmentalAnchor.relativeToOrigin: FloatArray(16)` — transform matrix
- `EnvironmentalAnchor.label: String` — debug identifier
- `anchorsCreated: Boolean` — chỉ tạo 1 lần

### Plane Finding
- Bật `HORIZONTAL_AND_VERTICAL` plane detection
- ARCore dùng planes để stabilize anchors
- Anchors gắn vào feature points trên planes → stable hơn floating anchors

---

## 3. Smooth Correction (Phase 3 + 5)

### Nguyên lý
Khi có observation mới (từ anchor hoặc QR), không snap ngay lập tức vì sẽ gây "nhảy" visual. Thay vào đó, lerp position và rotation trong 25 frames (~0.8 giây).

### Trigger conditions

| Source | Delta range | Action |
|--------|-------------|--------|
| QR re-observed | < 1mm | Snap trực tiếp (không thấy) |
| QR re-observed | 1mm – 500mm | Smooth lerp 25 frames |
| QR re-observed | > 500mm | Snap (tracking đã mất) |
| Env anchor | > 2mm, < 1000mm | Smooth lerp 25 frames |
| Env anchor | ≤ 2mm | Ignore (noise) |

### Lerp Algorithm
```kotlin
// Mỗi frame khi correction active:
t = 1.0 / correctionFramesRemaining  // exponential ease-out

// Position lerp (columns 12, 13, 14 of 4x4 matrix):
lockedOriginMatrix[12] += (target[12] - lockedOriginMatrix[12]) * t
lockedOriginMatrix[13] += (target[13] - lockedOriginMatrix[13]) * t
lockedOriginMatrix[14] += (target[14] - lockedOriginMatrix[14]) * t

// Rotation lerp (columns 0-2, rows 0-2):
for col in 0..2:
    for row in 0..2:
        lockedOriginMatrix[col*4 + row] += (target[col*4 + row] - current[col*4 + row]) * t

// Re-orthogonalize (Gram-Schmidt):
reorthogonalize(lockedOriginMatrix)

correctionFramesRemaining--
if correctionFramesRemaining == 0:
    lockedOriginMatrix = target  // snap on last frame
```

### Re-orthogonalization (Gram-Schmidt)
Sau lerp, rotation axes có thể không còn unit length hoặc perpendicular:
```kotlin
X = normalize(column0)
Y = Y - dot(Y, X) * X
Y = normalize(Y)
Z = cross(X, Y)
```

### Biến số
- `correctionTarget: FloatArray?` — target matrix (null = no correction active)
- `correctionFramesRemaining: Int` — countdown
- `CORRECTION_FRAMES = 25` — ~0.8s at 30fps

### Tại sao exponential ease-out
- `t = 1/remaining` → di chuyển nhiều ở đầu, ít ở cuối
- Frame 1: move 1/25 = 4% of remaining distance
- Frame 2: move 1/24 = 4.2%
- Frame 24: move 1/2 = 50%
- Frame 25: snap to target
- Kết quả: smooth deceleration, không có discontinuity

---

## 4. Confidence Score (Phase 4)

### Công thức
```
timeDecay = max(0, 1.0 - timeSinceLastAnchorSec / 120.0)
pathDecay = max(0, 1.0 - accumulatedPathLength × 0.005)
confidence = min(timeDecay, pathDecay)

// Override:
if QR visible this frame:
    confidence = 1.0
    accumulatedPathLength = 0  // reset
```

### Ý nghĩa
- **timeDecay**: sau 120 giây không anchor → confidence = 0
- **pathDecay**: sau 200m di chuyển → confidence = 0
- **min()**: lấy worst case — nếu 1 trong 2 xấu thì confidence thấp
- **QR visible**: ground truth → always 100%

### Path Length Tracking
```kotlin
// Mỗi frame:
dx = camPos[0] - lastCamPos[0]
dy = camPos[1] - lastCamPos[1]
dz = camPos[2] - lastCamPos[2]
dist = sqrt(dx² + dy² + dz²)

if dist < 1.0:  // ignore teleports (tracking glitch)
    accumulatedPathLength += dist
```

### UI Feedback Levels

| Confidence | Color | Message | Action |
|-----------|-------|---------|--------|
| > 70% | 🟢 Green | "Tracking stable (X%)" | Normal operation |
| 40–70% | 🟡 Amber | "Tracking via VIO (X%)" | Warn user |
| < 40% | 🔴 Red | "Low confidence — look at landmark" | Urge re-observation |
| QR visible | 🟢 Green | "QR visible — full accuracy" | Best state |
| Frozen | 🔴 Red | "POSITION STALE" | Block operations |

### Flutter Communication
```kotlin
// Gửi mỗi 15 frames (~0.5s), chỉ khi thay đổi > 2%:
channel.invokeMethod("onConfidenceUpdate", mapOf(
    "confidence" to confidenceScore,
    "timeSinceAnchorSec" to timeSinceAnchor,
    "pathLengthM" to accumulatedPathLength,
    "qrVisible" to qrVisibleThisFrame,
    "frozen" to isFrozen,
    "trackingAnchors" to activeAnchorCount,
))
```

---

## 5. Dead Reckoning Ceiling (Phase 6)

### Nguyên lý
Thông tin sai nguy hiểm hơn không có thông tin. Nếu không có anchor observation quá lâu, drift có thể > 30cm → freeze thay vì tiếp tục cho user data sai.

### Hard Limit
```
DEAD_RECKONING_LIMIT = 90 seconds
```

### Freeze Behavior
Khi `timeSinceLastAnchor > 90s`:
1. `isFrozen = true`
2. **Stop updating** `lockedOriginMatrix` — giữ vị trí cuối cùng tin cậy
3. **Stop updating** camera relative position — node placement disabled
4. Render content **xám mờ** (dim gray) thay vì màu bình thường
5. Flutter overlay đỏ: "POSITION DATA STALE — return to QR code"
6. Nút "Add Node" bị disable

### Recovery
Khi QR hoặc anchor thấy lại:
1. `isFrozen = false`
2. `accumulatedPathLength = 0` — reset
3. Apply smooth correction (Phase 5) về vị trí đúng
4. Notify Flutter → hide overlay
5. Restore normal rendering colors
6. Re-enable "Add Node"

### Tại sao 90 giây
- ARCore VIO drift ~1% distance
- Tốc độ đi bộ trung bình: ~1.4 m/s
- 90s × 1.4 m/s = 126m di chuyển
- 1% × 126m = 1.26m drift — quá lớn cho navigation
- Nhưng trong thực tế, environmental anchors sẽ correct trước khi tới 90s
- 90s là **absolute worst case** khi tất cả anchors đều mất

---

## 6. Drift Budget Analysis

### Nguồn drift

| Nguồn | Rate | Sau 60s (đi bộ) | Sau 180s |
|-------|------|-----------------|----------|
| ARCore VIO (tốt) | 0.5% distance | ~42mm | ~126mm |
| ARCore VIO (xấu) | 2% distance | ~168mm | ~504mm |
| Với env anchors | ~0.1% effective | ~8mm | ~25mm |
| Với QR re-observe | 0mm (reset) | 0mm | 0mm |

### Giả định
- Tốc độ đi bộ: 1.4 m/s
- 60s → 84m di chuyển
- 180s → 252m di chuyển

### Kết luận
- **Mục tiêu < 10cm/60s**: đạt được nếu có ≥ 1 anchor tracking (8mm << 100mm)
- **Mục tiêu < 30cm/180s**: đạt được nếu có ≥ 1 anchor tracking (25mm << 300mm)
- **Không anchor**: chỉ đạt mục tiêu trong ~60s (VIO thuần), sau đó cần freeze

---

## 7. Sequence Diagram

```
User scans QR → Origin locked → Anchors created
    │
    ├── User walks away (QR not visible)
    │   ├── VIO maintains world frame
    │   ├── Anchors still tracking → confidence high
    │   ├── Render axes + nodes normally
    │   │
    │   ├── [30s later] Some anchors lose tracking
    │   │   └── Confidence drops to 70%
    │   │       └── UI: "Tracking via VIO (70%)"
    │   │
    │   ├── [60s later] All anchors lost
    │   │   └── Confidence drops to 50%
    │   │       └── UI: "Look at a landmark"
    │   │
    │   ├── [90s later] Dead reckoning ceiling
    │   │   └── FREEZE
    │   │       └── UI: "POSITION STALE"
    │   │       └── Content gray, node placement disabled
    │   │
    │   └── User returns to QR / anchor
    │       ├── Observation received
    │       ├── Compute correction delta
    │       ├── Smooth lerp over 25 frames
    │       ├── Confidence → 100%
    │       ├── Unfreeze
    │       └── UI: "Tracking recovered"
    │
    └── User stays near QR
        ├── QR visible every frame
        ├── Confidence always 100%
        ├── lockedOriginMatrix updated from QR (ground truth)
        └── Maximum accuracy
```

---

## 8. Implementation Files

### Native (Kotlin)
```
android/app/src/main/kotlin/com/qrorigin/ArCoreAxesView.kt
```

Chứa tất cả logic:
- VIO tracking (lockedOriginMatrix persistence)
- Environmental anchor creation + monitoring
- Smooth correction (lerp + Gram-Schmidt)
- Confidence computation
- Dead reckoning freeze/unfreeze
- MethodChannel communication to Flutter

### Flutter
```
lib/screens/ar_axes_screen.dart
```

Handles:
- `onConfidenceUpdate` → update status bar color + text + progress bar
- `onDeadReckoningFreeze` → show/hide freeze overlay
- Disable "Add Node" when frozen
- Display: confidence %, anchor count, path length

---

## 9. Configuration Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `CORRECTION_FRAMES` | 25 | Frames to lerp correction (~0.8s) |
| `DEAD_RECKONING_LIMIT_MS` | 90,000 | Max time without anchor (ms) |
| Confidence time decay | 120s → 0 | Full decay in 2 minutes |
| Confidence path decay | 200m → 0 | Full decay at 200m walked |
| Anchor offsets | ±0.5m XZ, +0.3m Y | Positions around QR |
| Max correction delta | 1.0m | Ignore corrections > 1m (glitch) |
| Min correction delta | 0.002m | Ignore corrections < 2mm (noise) |
| QR snap threshold | 0.001m | Snap if < 1mm (no visible jump) |
| QR lerp threshold | 0.5m | Lerp if 1mm–500mm |
| QR hard snap | > 0.5m | Snap immediately (tracking lost) |
| Teleport filter | > 1.0m/frame | Ignore path length (glitch) |

---

## 10. Relationship with Flow 1

```
Flow 1 (QR Scan)                    Flow 2 (Maintain)
─────────────────                   ─────────────────
Detect QR                           ← lockedOriginMatrix
Multi-frame average                 ← lockedOriginPose
Gravity alignment                   
Verification                        
Origin Lock ──────────────────────→ VIO takes over
                                    Anchors created
                                    Confidence tracking
                                    Smooth corrections
                                    Dead reckoning ceiling
```

Flow 1 output = Flow 2 input:
- `lockedOriginMatrix` (4×4) — the established origin
- `lockedOriginPose` (Pose) — for compose operations
- `originLocked = true` — enables Flow 2 logic

Flow 2 maintains the origin established by Flow 1, correcting drift when possible, and freezing when correction is no longer possible.
