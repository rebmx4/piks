"""Codemagic API with a DPAPI-encrypted token outside the repository."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request
import urllib.parse

APP_ID = "6a63db4c3af355606a7e671e"
API = "https://api.codemagic.io"


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urllib.parse.urlparse(newurl).hostname not in ("api.codemagic.io", "codemagic.io"):
            redirected.remove_header("X-auth-token")
        return redirected


def download(url):
    if not url.startswith("https://"):
        raise RuntimeError("Unexpected download URL protocol")
    host = urllib.parse.urlparse(url).hostname
    headers = {"x-auth-token": token()} if host in ("api.codemagic.io", "codemagic.io") else {}
    req = urllib.request.Request(url, headers=headers)
    return urllib.request.build_opener(SafeRedirect()).open(req, timeout=60)


def token():
    if os.environ.get("CODEMAGIC_API_TOKEN"):
        return os.environ["CODEMAGIC_API_TOKEN"]
    script = r"""
$piksSecretPath=Join-Path $env:LOCALAPPDATA 'PiksNative\codemagic-token.xml'
$piksSecure=Import-Clixml -LiteralPath $piksSecretPath
$piksPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($piksSecure)
try {[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($piksPointer))}
finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($piksPointer)}
"""
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, check=True)
    return result.stdout.decode().strip()


def request(path, method="GET", body=None):
    payload = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=payload, method=method,
        headers={"x-auth-token": token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Never dump a request, headers or credential.
        raise RuntimeError(f"Codemagic API HTTP {error.code}: {error.read().decode()[:400]}") from None


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("apps")
    start = sub.add_parser("start")
    start.add_argument("--workflow", default="native-validate")
    start.add_argument("--branch", default="native-production")
    status = sub.add_parser("status")
    status.add_argument("build_id")
    inspect = sub.add_parser("inspect")
    inspect.add_argument("build_id")
    logs = sub.add_parser("logs")
    logs.add_argument("build_id")
    logs.add_argument("--out", required=True)
    artifacts = sub.add_parser("artifacts")
    artifacts.add_argument("build_id")
    artifacts.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.command == "apps":
        response = request("/apps")
        apps = response.get("applications", response.get("apps", [])) if isinstance(response, dict) else response
        print(json.dumps([{k: app.get(k) for k in ("_id", "id", "appName", "name", "repository")}
                          for app in apps if "piks" in json.dumps(app).lower()], ensure_ascii=False))
    elif args.command == "start":
        print(json.dumps(request("/builds", "POST", {"appId": APP_ID, "workflowId": args.workflow, "branch": args.branch})))
    else:
        response = request("/builds/" + args.build_id)
        build = response.get("build", response)
        if args.command == "inspect":
            print(json.dumps({"responseKeys": list(response), "buildKeys": list(build),
                "nested": {k: list(v)[:12] for k, v in build.items() if isinstance(v, dict)},
                "lists": {k: [list(v[0])] if v and isinstance(v[0], dict) else len(v) for k, v in build.items() if isinstance(v, list)},
                "actions": [{"name": x.get("name"), "subkeys": [list(s) for s in x.get("subactions", [])]} for x in build.get("buildActions", [])]}))
        elif args.command == "artifacts":
            folder = pathlib.Path(args.out); folder.mkdir(parents=True, exist_ok=True)
            for artifact in build.get("artefacts", []):
                url = artifact.get("url", artifact.get("downloadUrl"))
                name = pathlib.Path(artifact.get("name", "artifact.zip")).name
                if not url or not url.startswith("https://"):
                    print("Artifact metadata keys:", list(artifact)); continue
                with download(url) as response:
                    (folder / name).write_bytes(response.read())
                print("Downloaded", name)
        elif args.command == "logs":
            output = []
            def actions(items):
                for item in items:
                    yield item
                    yield from actions(item.get("subactions", []))
            for action in actions(build.get("buildActions", [])):
                if action.get("logUrl"):
                    url = action["logUrl"]
                    if not url.startswith("https://"):
                        raise RuntimeError("Unexpected log URL protocol")
                    with download(url) as response:
                        content = response.read().decode("utf-8", errors="replace")
                    output.append(action.get("name", "step") + "\n" + content)
            pathlib.Path(args.out).write_text("\n\n".join(output), encoding="utf-8")
            print(f"Saved {len(output)} build step logs")
        else:
            compact = {key: build.get(key) for key in ("_id", "status", "branch", "startedAt", "finishedAt")}
            compact["steps"] = [{k: step.get(k) for k in ("name", "status")} for step in build.get("buildActions", [])]
            print(json.dumps(compact, ensure_ascii=False))


if __name__ == "__main__":
    main()
