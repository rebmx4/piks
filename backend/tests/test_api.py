import io
import json
import tempfile
import unittest
from pathlib import Path
from backend.auth import AuthService
from backend.api import IdentityAPI


class APITests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.sent = []
        service = AuthService(Path(self.folder.name) / "db.sqlite", mailer=lambda *args: self.sent.append(args),
                              secret=b"local-unit-test-secret-32-bytes-minimum")
        self.api = IdentityAPI(service, email_enabled=True)

    def tearDown(self): self.folder.cleanup()

    def request(self, path, method="POST", data=None, authorization=None, origin=None):
        body = json.dumps(data or {}).encode()
        env = {"REQUEST_METHOD": method, "PATH_INFO": path, "CONTENT_LENGTH": str(len(body)),
               "CONTENT_TYPE": "application/json", "wsgi.input": io.BytesIO(body), "REMOTE_ADDR": "127.0.0.1"}
        if authorization: env["HTTP_AUTHORIZATION"] = "Bearer " + authorization
        if origin: env["HTTP_ORIGIN"] = origin
        result = []
        output = b"".join(self.api(env, lambda status, headers: result.append((status, headers))))
        return int(result[0][0].split()[0]), json.loads(output), dict(result[0][1])

    def testEmailRoundtripAndDeletionRequiresOwnAccessToken(self):
        email, password = "me@example.test", "unique longer test password"
        status, registered, _ = self.request("/v1/auth/register", data={"email": email, "password": password})
        self.assertEqual(status, 200)
        status, session, _ = self.request("/v1/auth/verify-email", data={"email": email, "code": self.sent[-1][1], "registrationId": registered["registrationId"]})
        self.assertEqual(status, 200)
        self.assertEqual(self.request("/v1/me", "GET", authorization=session["accessToken"])[0], 200)
        self.assertEqual(self.request("/v1/account/delete", data={"userId": session["user"]["id"]})[0], 401)
        self.assertEqual(self.request("/v1/account/delete", authorization=session["accessToken"])[0], 200)
        self.assertEqual(self.request("/v1/me", "GET", authorization=session["accessToken"])[0], 401)

    def testServiceDoesNotAcceptMediaOrProjectUploads(self):
        for path in ["/v1/media", "/v1/projects", "/v1/upload", "/v1/storage"]:
            self.assertEqual(self.request(path, data={"video": "data"})[0], 404)

    def testResponsesAreNotCachedAndDoNotEnableBrowserCORS(self):
        status, body, headers = self.request("/health", "GET")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request("/v1/auth/login", origin="https://attacker.example")[0], 403)

    def testUnavailableMailerIsReportedInCapabilities(self):
        self.api.email_enabled = False
        status, body, _ = self.request("/v1/capabilities", "GET")
        self.assertEqual(status, 200)
        self.assertFalse(body["email"])
        self.assertEqual(self.request("/v1/auth/register", data={"email": "me@example.test", "password": "password long enough"})[0], 503)

    def testMissingParametersAreClientErrorsWithoutTracebacks(self):
        status, body, _ = self.request("/v1/auth/register", data={})
        self.assertEqual(status, 400)
        self.assertNotIn("Traceback", json.dumps(body))


if __name__ == "__main__": unittest.main()
