"""Compile and test only the pure Swift package on the owner's existing Linux host."""
import argparse
import pathlib
import subprocess
import sys
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="root@64.112.125.97")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[2]
    remote_root = "/opt/piks-native-tools/core-check"
    with tempfile.TemporaryDirectory(prefix="piks-core-") as temporary:
        archive = pathlib.Path(temporary) / "core.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for file in sorted((root / "NativeCore").rglob("*")):
                if file.is_file() and not any(p in file.parts for p in (".build", ".swiftpm")):
                    tar.add(file, arcname=str(file.relative_to(root / "NativeCore")))
        subprocess.run(["scp", "-q", str(archive), args.host + ":/opt/piks-native-tools/core.tar.gz"], check=True)
    script = """
import os,subprocess,tarfile
root='/opt/piks-native-tools/core-check'
os.makedirs(root,exist_ok=True)
with tarfile.open('/opt/piks-native-tools/core.tar.gz') as archive:
    archive.extractall(root,filter='data')
swift='/opt/piks-native-tools/swift-6.4.0-RELEASE-debian13/usr/bin/swift'
result=subprocess.run(['nice','-n','15',swift,'test','--jobs','1'],cwd=root)
raise SystemExit(result.returncode)
"""
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", args.host, "python3 -"], input=script.encode())
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
