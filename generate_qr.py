"""Generate a high-quality QR code reference image for ARCore augmented image tracking.
ARCore needs images with good feature points - QR codes work well due to high contrast patterns.
"""
import qrcode
from PIL import Image, ImageDraw

# Create QR with high error correction and larger size
qr = qrcode.QRCode(
    version=3,  # Larger version = more modules = more features
    error_correction=qrcode.constants.ERROR_CORRECT_H,
    box_size=30,  # Larger boxes
    border=4,
)
qr.add_data("QR_ORIGIN_MARKER_001")
qr.make(fit=True)

img = qr.make_image(fill_color="black", back_color="white").convert("RGB")

# Add a distinctive border pattern to help ARCore with feature detection
draw = ImageDraw.Draw(img)
w, h = img.size
# Draw corner markers (extra features for ARCore)
marker_size = 20
for x, y in [(0, 0), (w - marker_size, 0), (0, h - marker_size), (w - marker_size, h - marker_size)]:
    draw.rectangle([x, y, x + marker_size, y + marker_size], fill="black")

img.save("assets/qr_reference.jpg", "JPEG", quality=98)
print(f"QR code saved: assets/qr_reference.jpg ({img.size[0]}x{img.size[1]} px)")
print("Print this at exactly 15x15cm for accurate tracking.")
