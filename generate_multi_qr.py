"""Generate multiple QR code images for multi-anchor system.
Each QR encodes a unique ID that matches the config file.
"""
import qrcode
import json
import os

# Load config
with open("assets/qr_anchors_config.json", "r") as f:
    config = json.load(f)

os.makedirs("assets/qr_anchors", exist_ok=True)

for anchor in config["anchors"]:
    qr_id = anchor["id"]
    label = anchor["label"]

    qr = qrcode.QRCode(
        version=3,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=30,
        border=4,
    )
    qr.add_data(qr_id)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    filename = f"assets/qr_anchors/{qr_id}.jpg"
    img.save(filename, "JPEG", quality=98)
    print(f"  {filename} ({img.size[0]}x{img.size[1]}) — {label}")

# Also save primary as the main reference (backward compat)
primary = next(a for a in config["anchors"] if a["primary"])
qr = qrcode.QRCode(version=3, error_correction=qrcode.constants.ERROR_CORRECT_H, box_size=30, border=4)
qr.add_data(primary["id"])
qr.make(fit=True)
img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
img.save("assets/qr_reference.jpg", "JPEG", quality=98)
print(f"\n  Primary QR also saved as assets/qr_reference.jpg")
print(f"\nTotal: {len(config['anchors'])} QR codes generated.")
print("Print each at 15x15cm. Measure with calipers.")
