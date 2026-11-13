"""Fetch public, hash-checked ML inputs into an explicit build directory."""
import hashlib
import pathlib
import sys
import urllib.request

output = pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
files = (
    ('selfie_multiclass_256x256.tflite',
     'https://rynpro.ru/ryn-ai/mediapipe-1.0.1/selfie_multiclass_256x256.tflite',
     'c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0'),
    ('portrait.jpg', 'https://storage.googleapis.com/mediapipe-assets/portrait.jpg',
     'a6f11efaa834706db23f275b6115058fa87fc7f14362681e6abe14e82749de3e'),
)
for name, url, expected in files:
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    actual = hashlib.sha256(data).hexdigest()
    if expected is not None and actual != expected:
        raise SystemExit(f'Hash mismatch: {name}')
    if name.endswith('.jpg') and not data.startswith(b'\xff\xd8'):
        raise SystemExit('Not a JPEG public fixture')
    (output / name).write_bytes(data)
    print(f'{name} bytes={len(data)} sha256={actual}')
