"""Deploy only the isolated APIKS identity service to the owner's existing VPS."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import time
import urllib.request


def wait_health(url, *, opener=None, sleep=time.sleep, attempts=10):
    opener = opener or urllib.request.urlopen
    for attempt in range(attempts):
        try:
            with opener(url, timeout=2) as response:
                if json.load(response).get("ok") is True: return True
        except (OSError, ValueError, AttributeError):
            pass
        if attempt + 1 < attempts: sleep(0.3)
    return False


def inject_nginx(text):
    include = "    include /etc/nginx/snippets/piks-native-auth.conf;\n"
    if include in text: return text
    if "/piks-auth/" in text:
        raise ValueError("Existing /piks-auth/ location belongs to another configuration")
    anchors = list(re.finditer(r"^[ \t]*server_name rynpro\.ru;[^\n]*\n", text, re.MULTILINE))
    if len(anchors) != 1:
        raise ValueError("Canonical HTTPS host is missing or ambiguous")
    end = anchors[0].end()
    return text[:end] + include + text[end:]


REMOTE = r'''
import hashlib, json, os, pwd, secrets, shutil, socket, subprocess, sys, tarfile, tempfile, time, urllib.request
from pathlib import Path
release_id = "RELEASE_ID"
base = Path("/opt/piks-auth")
release = base / "releases" / release_id
if not release.resolve().is_relative_to(base.resolve()): raise RuntimeError("Unsafe release path")
run = lambda *args: subprocess.run(args, check=True)
run("nginx", "-t")
try: user = pwd.getpwnam("piks-auth")
except KeyError:
    run("useradd", "--system", "--home-dir", "/var/lib/piks-auth", "--shell", "/usr/sbin/nologin", "piks-auth")
    user = pwd.getpwnam("piks-auth")
if not (base / "current").exists():
    probe = socket.socket()
    try: probe.bind(("127.0.0.1", 8816))
    finally: probe.close()
release.mkdir(parents=True, exist_ok=True)
with tarfile.open(base / "incoming.tar.gz", "r:gz") as archive:
    archive.extractall(release, filter="data")
sys.path.insert(0, str(release))
os.chdir(release)
from backend.deploy import inject_nginx, wait_health
venv = release / ".venv"
if not venv.exists(): run("python3", "-m", "venv", str(venv))
run(str(venv / "bin/pip"), "install", "--disable-pip-version-check", "-r", str(release / "backend/requirements.txt"))
run(str(venv / "bin/python"), "-m", "unittest", "discover", "-s", str(release / "backend/tests"), "-v")
for path in [Path("/etc/piks-native"), Path("/var/lib/piks-auth")]:
    path.mkdir(exist_ok=True); os.chmod(path, 0o750); os.chown(path, 0 if str(path).startswith("/etc") else user.pw_uid, user.pw_gid)
key = Path("/etc/piks-native/auth.key")
if not key.exists():
    descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
    with os.fdopen(descriptor, "wb") as output: output.write(secrets.token_bytes(64))
    os.chown(key, 0, user.pw_gid)
config = Path("/etc/piks-native/config.json")
if not config.exists():
    config.write_text(json.dumps({"database": "/var/lib/piks-auth/accounts.sqlite", "secretFile": str(key)}, indent=2) + "\n")
    os.chmod(config, 0o640); os.chown(config, 0, user.pw_gid)
nginx = Path("/etc/nginx/sites-enabled/rynpro").resolve()
if not nginx.is_relative_to(Path("/etc/nginx")): raise RuntimeError("Unexpected Nginx configuration path")
original = nginx.read_text()
updated = inject_nginx(original)
def write_nginx(value, expected):
    if nginx.read_text() != expected: raise RuntimeError("Nginx changed in another session; stopping this deployment")
    info = nginx.stat()
    with tempfile.NamedTemporaryFile(mode="w", dir=nginx.parent, prefix=".piks-nginx-", delete=False) as output:
        output.write(value); stage = output.name
    os.chmod(stage, info.st_mode); os.chown(stage, info.st_uid, info.st_gid)
    os.replace(stage, nginx)
snapshot = base / "nginx-rynpro.before-piks"
if not snapshot.exists(): shutil.copy2(nginx, snapshot)
snippet = Path("/etc/nginx/snippets/piks-native-auth.conf")
if snippet.exists() and snippet.read_text() != (release / "backend/nginx-location.conf").read_text():
    raise RuntimeError("Nginx snippet already exists with a different owner configuration")
shutil.copyfile(release / "backend/nginx-location.conf", snippet)
try:
    if updated != original: write_nginx(updated, original)
    run("nginx", "-t")
except Exception:
    if nginx.read_text() == updated: write_nginx(original, updated)
    raise
current = base / "current"
previous = current.resolve() if current.exists() else None
if previous and not previous.is_relative_to(base.resolve()): raise RuntimeError("Unexpected current release path")
pending = base / "current.new"
if pending.is_symlink(): pending.unlink()
pending.symlink_to(release, target_is_directory=True); os.replace(pending, current)
unit = Path("/etc/systemd/system/piks-auth.service")
shutil.copyfile(release / "backend/piks-auth.service", unit)
try:
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "piks-auth")
    run("systemctl", "restart", "piks-auth")
    healthy = False
    for attempt in range(10):
        try:
            with urllib.request.urlopen("http://127.0.0.1:8816/health", timeout=2) as response:
                healthy = json.load(response).get("ok") is True
            if healthy: break
        except OSError: time.sleep(0.3)
    if not healthy: raise RuntimeError("Identity health check failed")
    run("systemctl", "reload", "nginx")
    if not wait_health("https://rynpro.ru/piks-auth/health"):
        raise RuntimeError("HTTPS health check failed")
except Exception:
    if nginx.read_text() == updated: write_nginx(original, updated)
    run("nginx", "-t"); run("systemctl", "reload", "nginx")
    if previous:
        pending.symlink_to(previous, target_is_directory=True); os.replace(pending, current)
        run("systemctl", "restart", "piks-auth")
    else: run("systemctl", "stop", "piks-auth")
    raise
print("APIKS identity release " + release_id + ": HTTPS health PASS; media routes absent.")
'''


def main():
    compile(REMOTE, "<piks-remote-deploy>", "exec")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="root@64.112.125.97")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"root@[A-Za-z0-9.-]+", args.host): parser.error("Invalid deployment host")
    root = Path(__file__).resolve().parents[1]
    files = sorted([p for p in (root / "backend").glob("*.py")] + list((root / "backend/tests").glob("*.py")) +
                   [root / "backend" / name for name in ["requirements.txt", "piks-auth.service", "nginx-location.conf"]])
    digest = hashlib.sha256(b"".join(str(p.relative_to(root)).encode() + p.read_bytes() for p in files)).hexdigest()[:16]
    if args.dry_run:
        print(f"Prepared identity release {digest}; destination /opt/piks-auth/releases/{digest}; route /piks-auth/; files {len(files)}")
        return
    output = root / ".superpowers/sdd/PLAN/auth-incoming.tar.gz"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w:gz") as archive:
        for path in files: archive.add(path, arcname=path.relative_to(root).as_posix(), recursive=False)
    subprocess.run(["ssh", "-o", "BatchMode=yes", args.host, "mkdir -p /opt/piks-auth"], check=True)
    subprocess.run(["scp", "-q", str(output), args.host + ":/opt/piks-auth/incoming.tar.gz"], check=True)
    subprocess.run(["ssh", "-o", "BatchMode=yes", args.host, "python3 -"],
                   input=REMOTE.replace("RELEASE_ID", digest).encode(), check=True)


if __name__ == "__main__": main()
