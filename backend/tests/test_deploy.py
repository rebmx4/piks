import unittest
import io
from backend.deploy import inject_nginx, REMOTE, wait_health


class DeploymentTests(unittest.TestCase):
    def testRemoteScriptCanBeCompiledBeforeConnectingToTheServer(self):
        compile(REMOTE, "<remote-deploy>", "exec")

    def testReloadWaitsForHTTPSRouteInsteadOfTreatingOldHTMLAsHealth(self):
        responses = iter([b"<html>Previous worker</html>", b'{"ok": true}'])
        self.assertTrue(wait_health("https://example.test/health", opener=lambda *_a, **_k: io.BytesIO(next(responses)), sleep=lambda *_: None))

    def testFailedHTTPSHealthDoesNotActivateRelease(self):
        self.assertFalse(wait_health("https://example.test/health", opener=lambda *_a, **_k: io.BytesIO(b"bad"), sleep=lambda *_: None, attempts=2))

    def testOnlyCanonicalHTTPSVirtualHostReceivesTheNewRoute(self):
        config = "server {\n server_name www.rynpro.ru;\n return 301 https://rynpro.ru$request_uri;\n}\nserver {\n server_name rynpro.ru;\n location /ryn/ { alias /frozen/; }\n}\n"
        added = "    include /etc/nginx/snippets/piks-native-auth.conf;\n"
        result = inject_nginx(config)
        self.assertEqual(result.replace(added, ""), config)
        self.assertEqual(result.count(added), 1)
        self.assertGreater(result.index(added), result.index("server_name rynpro.ru;"))
        self.assertEqual(inject_nginx(result), result)

    def testExistingForeignRouteIsNotOverwritten(self):
        with self.assertRaises(ValueError):
            inject_nginx("server {\n server_name rynpro.ru;\n location /piks-auth/ { proxy_pass http://other; }\n}\n")

    def testAmbiguousOrMissingCanonicalHostStopsDeployment(self):
        for text in ["server_name other.ru;", "server_name rynpro.ru;\nserver_name rynpro.ru;\n"]:
            with self.assertRaises(ValueError): inject_nginx(text)
