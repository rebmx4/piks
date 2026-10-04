"""Release boundaries and plist validation; media behavior is tested with XCTest."""
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2]
errors = []
for directory in ("NativeApp", "NativeEngine", "NativeCore", "NativeShareExtension"):
    for file in (root / directory).rglob("*.swift"):
        source = file.read_text(encoding="utf-8-sig")
        if re.search(r"\b(import\s+(WebKit|JavaScriptCore)|WKWebView|UIWebView|JSContext)\b", source):
            errors.append(f"Browser runtime in native target: {file.relative_to(root)}")
for file in (root / "NativeApp").rglob("*"):
    if file.suffix in (".plist", ".entitlements", ".xcprivacy"):
        with file.open("rb") as stream:
            plistlib.load(stream)
config = (root / "project-native.yml").read_text(encoding="utf-8")
if re.search(r"path:\s*(App|ShareExtension|web)\s*$", config, re.MULTILINE):
    errors.append("Old test-app or web sources included in the native project")
if "com.piks.app.native" not in config:
    errors.append("Native bundle identity is missing")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("Native target boundaries and property lists: PASS")
