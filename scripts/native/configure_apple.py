"""Configure only the new native app's primary Sign in with Apple capability."""
import http.client
import json
import os
import sys
import time

BUNDLE_ID = "com.piks.app.native"
SETTINGS = [{"key": "APPLE_ID_AUTH_APP_CONSENT",
             "options": [{"key": "PRIMARY_APP_CONSENT", "enabled": True}]}]


def configure(resource_id):
    import jwt  # Already supplied with Codemagic's app-store-connect CLI.

    now = int(time.time())
    bearer = jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"],
                         "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1"},
                        os.environ["APP_STORE_CONNECT_PRIVATE_KEY"], algorithm="ES256",
                        headers={"kid": os.environ["APP_STORE_CONNECT_KEY_IDENTIFIER"]})

    def request(path, method="GET", body=None):
        # A fixed TLS host prevents credentials following redirects to another server.
        connection = http.client.HTTPSConnection("api.appstoreconnect.apple.com", timeout=30)
        try:
            connection.request(method, "/v1/" + path,
                               json.dumps(body).encode() if body is not None else None,
                               {"Authorization": "Bearer " + bearer, "Content-Type": "application/json"})
            response = connection.getresponse()
            data = json.loads(response.read())
            if response.status >= 300:
                detail = data.get("errors", [{}])[0].get("detail", "Apple API rejected the request.")
                raise RuntimeError(f"Apple API HTTP {response.status}: {detail}")
            return data
        finally:
            connection.close()

    bundle = request("bundleIds/" + resource_id)["data"]
    if bundle["attributes"]["identifier"] != BUNDLE_ID:
        raise RuntimeError("Refusing to change a bundle other than the native app.")
    capabilities = request("bundleIds/" + resource_id + "/bundleIdCapabilities")["data"]
    apple = next((item for item in capabilities
                  if item["attributes"]["capabilityType"] == "APPLE_ID_AUTH"), None)
    if apple:
        if any(option.get("key") == "PRIMARY_APP_CONSENT" and option.get("enabled") is True
               for setting in apple["attributes"].get("settings", [])
               for option in setting.get("options", [])):
            print("Native primary Sign in with Apple is already configured.")
            return
        request("bundleIdCapabilities/" + apple["id"], "PATCH", {"data": {
            "id": apple["id"], "type": "bundleIdCapabilities", "attributes": {"settings": SETTINGS}}})
    else:
        request("bundleIdCapabilities", "POST", {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": "APPLE_ID_AUTH", "settings": SETTINGS},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": resource_id}}}}})
    print("Native primary Sign in with Apple configured.")


if __name__ == "__main__":
    try:
        configure(sys.argv[1])
    except Exception as error:
        # No environment values, JWTs, keys or request headers in logs.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        sys.exit("Native Apple configuration failed: " + message)
