# Flow 1 — Quét QR, Thiết lập Hệ trục Tọa độ Tuyệt đối

## Mục tiêu

Mỗi lần quét cùng 1 QR code phải ra **đúng 1 hệ trục tọa độ duy nhất**, với:
- Sai số vị trí (position) < 5mm
- Nhất quán giữa các session (đóng app mở lại → cùng kết quả)
- Nhất quán giữa các thiết bị khác nhau (2 điện thoại quét cùng QR → cùng hệ trục)

---

## Tổng quan Pipeline

```
Camera Frame → QR Detection → Angle Gate → Frame Collection → Outlier Rejection
    → Quaternion Averaging → Gravity Alignment → Verification → Origin Lock
```

---

## 1. QR Detection (ARCore Augmented Images)

### Kỹ thuật sử dụng
- **ARCore Augmented Image Database**: load ảnh QR reference vào database, ARCore tự detect và track
- ARCore trả về `AugmentedImage.centerPose` — một `Pose` object chứa position (x,y,z) và orientation (quaternion) của tâm QR trong world space

### Biến số
- `qrPhysicalSize = 0.15m` (15cm) — kích thước thật của QR đã in
- `AugmentedImage.centerPose` → `Pose(tx, ty, tz, qx, qy, qz, qw)`
- `AugmentedImage.trackingState` → TRACKING / PAUSED / STOPPED
- `AugmentedImage.trackingMethod` → FULL_TRACKING / LAST_KNOWN_POSE

### Yêu cầu vật lý
- QR in trên vật liệu cứng, phẳng tuyệt đối
- Gắn cố định, không rung
- Kích thước tối thiểu 15×15cm (ARCore cần ≥ 15cm cho tracking ổn định)
- Ánh sáng uniform — tránh bóng đổ chéo lên QR

### Tại sao kích thước quan trọng
- ARCore estimate distance dựa trên `Z = (focalLength × realSize) / pixelSize`
- Sai 1mm kích thước QR thật → sai ~7mm ở khoảng cách 1m
- **Phải đo bằng thước kẹp (caliper)**, không dùng thước dây

---

## 2. Angle Gate — Kiểm tra góc tiếp cận

### Kỹ thuật
- Tính **dot product** giữa camera forward vector và QR normal vector
- Camera forward = `-Z` axis của camera pose
- QR normal = `Z` axis của QR pose (hướng vuông góc mặt QR, ra phía camera)

### Công thức
```
angleScore = |dot(cameraForward, qrNormal)|
           = |(-camPose.zAxis) · (qrPose.zAxis)|
```

### Ngưỡng
- `threshold = cos(20°) ≈ 0.9397`
- Chỉ chấp nhận frame khi `angleScore > 0.9397`
- Nghĩa là camera phải trong phạm vi ±20° so với vuông góc mặt QR

### Hysteresis
- Khi đã bắt đầu collecting: nới threshold thêm 5° → `cos(25°) ≈ 0.9063`
- Tránh flicker (vừa collect vừa reject liên tục ở biên)

### Smoothing
- Rolling average 5 frames gần nhất
- Tránh 1 frame noise làm reject sai

### Tại sao cần
- Góc xiên > 20° → perspective distortion → corner detection lệch → pose sai
- Ở 30° xiên, sai số pose tăng ~3x so với vuông góc
- Đây là nguồn sai số lớn nhất mà dễ kiểm soát nhất

---

## 3. Frame Collection — Thu thập multi-frame

### Kỹ thuật
- Thu liên tục **30 frames** (~1 giây ở 30fps)
- Mỗi frame phải pass cả angle gate VÀ reprojection error check

### Temporal Coherence Check
Loại frame có **nhảy đột ngột** so với frame trước:

```
positionJump = |frame[i].position - frame[i-1].position|
rotationJump = 2 × acos(|dot(q[i], q[i-1])|)

Reject nếu:
  positionJump > 10mm  (tracking glitch)
  rotationJump > 5°    (rotation glitch)
```

### Spatial Clustering
Loại frame nằm **quá xa centroid** hiện tại:

```
centroid = mean(accepted_frames.position)
distance = |frame.position - centroid|
maxAllowed = max(3 × currentSpread, 5mm)

Reject nếu distance > maxAllowed
```

### Running Statistics (Welford's Algorithm)
Tính mean và variance online, không cần recompute toàn bộ mỗi frame:

```
n += 1
delta = x - mean
mean += delta / n
delta2 = x - mean
M2 += delta * delta2
variance = M2 / (n - 1)
stddev = sqrt(variance)
```

### Timeout
- Max 3 giây collection
- Nếu đủ ≥ 15 frames → compute
- Nếu < 15 frames → restart

### Biến số output
- `acceptedFrames[]` — list các PoseFrame đã pass tất cả checks
- `positionStdDev` — standard deviation vị trí (meters)
- `spatialSpread` — max distance từ centroid (meters)

---

## 4. Outlier Rejection — Lọc 2 lần

### Pass 1: Reprojection Error (σ-based)
```
errors = sort(frames.map(f => f.reprojectionError))
median = errors[len/2]
mean = sum(errors) / len
stddev = sqrt(sum((e - mean)²) / len)
threshold = median + 1.0 × stddev

Reject frame nếu frame.reprojectionError > threshold
```

### Pass 2: Positional Outlier
```
centroid = mean(filtered_frames.position)
distances = filtered_frames.map(f => |f.position - centroid|)
meanDist = mean(distances)
stddevDist = sqrt(variance(distances))
threshold = meanDist + 2.0 × stddevDist

Reject frame nếu |f.position - centroid| > threshold
```

### Tại sao 2 pass
- Pass 1 loại frame có detection kém (blur, partial occlusion)
- Pass 2 loại frame có position outlier (tracking jump nhỏ mà temporal check bỏ sót)

---

## 5. Quaternion Averaging — Eigenvalue Method

### Vấn đề
- Quaternion không thể average bằng arithmetic mean (kết quả không phải unit quaternion)
- Quaternion có tính antipodal: `q` và `-q` biểu diễn cùng rotation

### Hemisphere Alignment
Trước khi average, đảm bảo tất cả quaternion cùng hemisphere:
```
reference = frames[0].quaternion
for each frame:
    if dot(frame.q, reference) < 0:
        frame.q = -frame.q  // flip to same hemisphere
```

### Eigenvalue Method (chính xác nhất)
Xây dựng ma trận 4×4:
```
M = Σ(qi × qi^T)   // outer product of each quaternion with itself

M[i][j] = Σ(q_k[i] × q_k[j])  for all k frames
```

Tìm eigenvector ứng với eigenvalue lớn nhất bằng **Power Iteration**:
```
v = initial_guess (dùng reference quaternion)
repeat 50 times:
    v_next = M × v
    v_next = normalize(v_next)
    if |v_next - v| < 1e-10: break
    v = v_next

result = Quaternion(v[0], v[1], v[2], v[3]).normalized()
```

### Tại sao eigenvalue method
- Optimal trong nghĩa least-squares: minimize tổng angular distance tới tất cả input quaternions
- Iterative SLERP bị bias bởi thứ tự input
- Với 30 frames clustered gần nhau, cả 2 method cho kết quả gần giống, nhưng eigenvalue robust hơn khi có outlier nhẹ

### Fallback: Iterative SLERP
Dùng khi < 4 frames:
```
result = q[0]
for i = 1 to n-1:
    t = 1.0 / (i + 1)
    result = slerp(result, q[i], t)
```

---

## 6. Position Averaging

### Công thức
Simple arithmetic mean (vì position là Euclidean space):
```
avgPosition = (1/n) × Σ(frame[i].position)
```

### Sau outlier rejection, đây là unbiased estimator tốt nhất

---

## 7. Gravity Alignment — Snap Y-axis theo IMU

### Kỹ thuật
- IMU (accelerometer + gyroscope fusion) cho gravity vector với độ chính xác ~0.1°
- Snap trục Y của hệ tọa độ thẳng đứng theo gravity
- Loại bỏ roll/pitch error từ camera pose estimation

### Gravity Vector
- ARCore: gravity = (0, -9.81, 0) trong world space (Y-up convention)
- Accelerometer raw: trả về vector hướng xuống, magnitude ~9.81 m/s²
- Dùng average 30 samples gần nhất cho stable

### Validation
```
gravityMagnitude = |gravityVector|
gravityReliable = |gravityMagnitude - 9.81| < 0.5
```
Nếu magnitude sai quá → IMU unreliable (đang rung, đang rơi, etc.)

### Gram-Schmidt Orthogonalization
Rebuild orthonormal basis với Y = gravity-aligned up:

```
up = normalize(-gravityVector)  // "up" ngược hướng gravity

// 1. Y-axis mới = up (gravity-aligned)
newY = up

// 2. Z-axis = project Z cũ lên mặt phẳng vuông góc với newY
//    Giữ heading (yaw) từ QR detection
newZ = currentZ - newY × dot(currentZ, newY)
if |newZ| < 0.001:
    newZ = cross(currentX, newY)  // fallback
newZ = normalize(newZ)

// 3. X-axis = cross(Y, Z) — right-hand rule
newX = normalize(cross(newY, newZ))
```

### Heading Preservation Check
```
preHeading = extractYaw(poseMatrix, gravity)  // trước alignment
postHeading = extractYaw(alignedMatrix, gravity)  // sau alignment
headingChange = |postHeading - preHeading|

Assert: headingChange < 2°
```
Nếu heading thay đổi > 2° → alignment có bug

### Post-alignment Validation
```
postDelta = angleBetween(alignedMatrix.Y_axis, up)
Assert: postDelta < 0.1°
```

### Tại sao gravity alignment quan trọng
- Camera pose estimation có roll/pitch error ~1-3° (phụ thuộc góc quét)
- IMU gravity chính xác ~0.1°
- Snap Y theo gravity → "lên" luôn là "lên" dù user cầm điện thoại hơi nghiêng
- **Đây là yếu tố chính đảm bảo cross-device consistency** — 2 điện thoại khác nhau sẽ có cùng Y-axis vì gravity là hằng số vật lý

---

## 8. Confidence Score — Đánh giá chất lượng

### Công thức
```
posScore = clamp(1.0 - positionStdDev / 0.005, 0, 1)    // tốt nếu σ < 5mm
rotScore = clamp(1.0 - rotationSpread / 3.0, 0, 1)      // tốt nếu spread < 3°
accScore = clamp(acceptedFrames / totalFrames, 0, 1)     // tốt nếu > 70% accepted

confidence = 0.4 × posScore + 0.3 × rotScore + 0.3 × accScore
```

### Ngưỡng
- `confidence ≥ 0.5` → chấp nhận
- `confidence < 0.5` → reject, yêu cầu scan lại

### Ý nghĩa từng thành phần
- **posScore (40%)**: vị trí ổn định → QR không rung, tracking stable
- **rotScore (30%)**: rotation ổn định → góc quét consistent
- **accScore (30%)**: tỉ lệ frame tốt cao → ít noise/glitch

---

## 9. Verification — Quality Gate cuối

### Automated Checks (6 checks)

| # | Check | Điều kiện pass | Ý nghĩa |
|---|-------|---------------|----------|
| 1 | Matrix Orthonormality | deviation < 0.001 | Ma trận rotation hợp lệ |
| 2 | Position Magnitude | 0.1m < |pos| < 10m | QR ở khoảng cách hợp lý |
| 3 | Up Vector Alignment | dot(Y, worldUp) > 0.99 | Gravity alignment đúng |
| 4 | Confidence Score | ≥ 0.5 | Đủ chất lượng |
| 5 | Position Stability | σ < 5mm | Vị trí ổn định |
| 6 | Gravity Alignment | delta < 0.5° | Y-axis thẳng đứng |

### Visual Verification
- Project test point (1m phía trước QR) lên screen
- User confirm crosshair trùng với vật thật
- Nếu lệch → reject → re-scan

### Cross-session Comparison
- So sánh origin mới với origin đã lưu trước đó cho cùng QR ID
- `positionDiff < 5mm` VÀ `rotationDiff < 1°` → consistent
- Nếu khác biệt lớn → cảnh báo user

---

## 10. Origin Storage — Lưu trữ

### Format
- 4×4 homogeneous matrix, **column-major**, 16 doubles
- **KHÔNG BAO GIỜ** dùng Euler angles (gimbal lock)
- JSON serialization với schema version

### Rule bất di bất dịch
```
Mọi object trong scene lưu pose RELATIVE TO ORIGIN.
Không bao giờ lưu absolute world pose.

objectRelativePose = originMatrix.inverse() × objectWorldPose
objectWorldPose = originMatrix × objectRelativePose
```

### Tại sao relative
- World pose thay đổi mỗi session (ARCore khởi tạo world frame khác nhau)
- Relative pose cố định vì origin luôn được thiết lập từ cùng QR
- Cross-device: 2 điện thoại có world frame khác nhau, nhưng relative pose giống nhau

---

## 11. Đo lường độ chính xác

### Metrics thu thập mỗi lần scan

| Metric | Đơn vị | Mục tiêu | Cách tính |
|--------|--------|-----------|-----------|
| Position σ | mm | < 2mm | Std dev of accepted frame positions |
| Rotation spread | ° | < 1° | Std dev of angular distance to mean quaternion |
| Gravity delta | ° | < 0.1° | Angle between Y-axis and gravity after alignment |
| Acceptance ratio | % | > 70% | accepted_frames / total_frames |
| Confidence | 0-1 | > 0.7 | Weighted combination |
| Cross-session Δpos | mm | < 5mm | |current.pos - previous.pos| |
| Cross-session Δrot | ° | < 1° | Angular distance between quaternions |

### Cách validate cross-device
1. 2 điện thoại quét cùng QR
2. Export origin matrix từ cả 2
3. So sánh: `|pos1 - pos2|` phải < 5mm, `angleDiff(q1, q2)` phải < 1°

### Nguồn sai số và magnitude

| Nguồn | Magnitude | Mitigation |
|-------|-----------|-----------|
| QR physical size sai | ~7mm/mm sai ở 1m | Đo bằng caliper |
| Góc quét xiên | ~3x error ở 30° | Angle gate ±20° |
| Single frame noise | ~2-5mm | Multi-frame averaging 30 frames |
| Tracking glitch | ~50mm spike | Temporal coherence + outlier rejection |
| Camera roll/pitch | ~1-3° | Gravity alignment (IMU ~0.1°) |
| Lighting non-uniform | ~1-3mm | Yêu cầu ánh sáng đều |
| QR surface không phẳng | ~1-2mm | Yêu cầu vật liệu cứng |

---

## 12. State Machine

```
SCANNING → COLLECTING → AVERAGING → VERIFYING → LOCKED
    ↑                                      |
    └──────────── (reject) ────────────────┘
```

| State | Trigger vào | Trigger ra | Hành động |
|-------|-------------|-----------|-----------|
| SCANNING | App start / Reset | First valid frame | Chờ QR, show angle feedback |
| COLLECTING | First valid frame | 30 frames hoặc timeout | Thu frame, check quality |
| AVERAGING | 30 frames collected | Computation done | Lọc + average + gravity align |
| VERIFYING | Origin computed | User confirm/reject | Show verification UI |
| LOCKED | User confirm | Reset | Origin active, render axes + nodes |

---

## 13. Coordinate Convention

```
Hệ tọa độ QR Origin (right-handed):

        Y (green)
        ↑ (gravity up)
        |
        |
        O ———→ X (red, dọc cạnh trên QR)
       /
      /
     ↓ Z (blue, vuông góc mặt QR, hướng ra camera)
```

- **Origin O** = tâm QR code
- **X** = hướng phải khi nhìn thẳng vào QR
- **Y** = hướng lên (gravity-aligned, vuông góc mặt đất)
- **Z** = hướng ra khỏi mặt QR (về phía camera)
- Đơn vị: **meters**
- Rotation: **quaternion (x, y, z, w)**
- Matrix: **4×4 column-major homogeneous**

---

## 14. Dependencies & Tech Stack

| Component | Technology | Vai trò |
|-----------|-----------|---------|
| AR Engine | ARCore (native Kotlin) | Camera, tracking, augmented images |
| 3D Rendering | OpenGL ES 2.0 (native) | Render axes + nodes trong AR |
| UI Framework | Flutter | Overlay UI, node management |
| Bridge | PlatformView (Hybrid Composition) | Embed native GL view trong Flutter |
| QR Detection | ARCore Augmented Image Database | Detect + track QR 6DOF |
| Gravity | ARCore IMU (accelerometer + gyro fusion) | Gravity vector cho Y-axis alignment |
| Storage | JSON file (path_provider) | Persist origin matrix |
| Math | vector_math (Dart) + android.opengl.Matrix (Kotlin) | Matrix/quaternion operations |

---

## 15. File Structure (Implementation)

```
android/app/src/main/kotlin/com/qrorigin/
├── ArCoreAxesView.kt      — Native ARCore view + OpenGL renderer
├── ArCoreViewFactory.kt   — PlatformView factory
└── MainActivity.kt        — Plugin registration

lib/
├── screens/ar_axes_screen.dart    — Flutter UI wrapper
├── models/world_origin.dart       — Origin data model + serialization
├── pipeline/
│   ├── pose_averager.dart         — Outlier rejection + eigenvalue averaging
│   ├── gravity_aligner.dart       — Gram-Schmidt Y-axis snap
│   ├── angle_gate.dart            — Dot product angle check
│   ├── frame_collector.dart       — Temporal coherence + spatial clustering
│   └── origin_verifier.dart       — Automated quality checks
├── services/
│   ├── origin_storage_service.dart — JSON persistence + history
│   └── ar_service_interface.dart   — Abstract interface
└── config/app_config.dart          — Tuning parameters
```
