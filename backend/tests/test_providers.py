import tempfile
import hashlib
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from backend.auth import AuthError, AuthService
from backend.providers import ProviderVerifier


class KeyClient:
    def __init__(self, key): self.key = key
    def get_signing_key_from_jwt(self, token): return type("Key", (), {"key": self.key})()


class ProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.verifier = ProviderVerifier(apple_audience="com.piks.app.native", google_audiences=["native-google-client"],
                                         key_clients={"apple": KeyClient(self.key.public_key()), "google": KeyClient(self.key.public_key())})
        self.service = AuthService(Path(self.folder.name) / "users.sqlite", mailer=lambda *args: None,
            secret=b"local-unit-test-secret-32-bytes-minimum", providers=self.verifier)

    def tearDown(self): self.folder.cleanup()

    def token(self, nonce_value, **overrides):
        payload = {"iss": "https://accounts.google.com", "aud": "native-google-client", "sub": "user-123",
                   "exp": int(time.time()) + 300, "iat": int(time.time()), "email": "me@example.test",
                   "email_verified": True, "nonce": nonce_value}
        payload.update(overrides)
        return jwt.encode(payload, self.key, algorithm="RS256", headers={"kid": "unit-test-key"})

    def testSignedProviderLoginRequiresCorrectAudienceIssuerAndNonce(self):
        challenge = self.service.challenge("google", "ip1")
        for changes in [{"aud": "someone-else"}, {"iss": "https://attacker.example"}, {"exp": 1}, {"email_verified": False}, {"nonce": "wrong"}]:
            with self.assertRaises(AuthError):
                self.service.provider_login("google", self.token(challenge["nonce"], **changes), challenge["id"], "ip1")
        result = self.service.provider_login("google", self.token(challenge["nonce"]), challenge["id"], "ip1")
        self.assertEqual(self.service.me(result["accessToken"])["email"], "me@example.test")

    def testChallengeIsSingleUse(self):
        challenge = self.service.challenge("google", "ip1")
        token = self.token(challenge["nonce"])
        self.service.provider_login("google", token, challenge["id"], "ip1")
        with self.assertRaises(AuthError): self.service.provider_login("google", token, challenge["id"], "ip1")

    def testUnsignedTokenAndHMACAlgorithmCannotBeAcceptedAsRSA(self):
        for algorithm, key in [("none", None), ("HS256", b"attacker supplied key with 32 bytes minimum")]:
            token = jwt.encode({"sub": "victim", "aud": "native-google-client"}, key, algorithm=algorithm)
            with self.assertRaises(AuthError): self.verifier.verify("google", token)

    def testProviderIdentityDoesNotAutomaticallyLinkByEmail(self):
        self.service.register("me@example.test", "an existing strong password", "ip1")
        with self.service.transaction() as db:
            existing = db.execute("select id from users").fetchone()[0]
        c = self.service.challenge("google", "ip1")
        result = self.service.provider_login("google", self.token(c["nonce"]), c["id"], "ip1")
        self.assertNotEqual(result["user"]["id"], existing)

    def testUnknownProviderIsRejected(self):
        with self.assertRaises(AuthError): self.service.challenge("custom", "ip1")

    def testExpiredAppleChallengeDoesNotConsumeTheOneTimeAuthorizationCode(self):
        challenge = self.service.challenge("apple", "ip1")
        nonce = hashlib.sha256(challenge["nonce"].encode()).hexdigest()
        token = self.token(nonce, iss="https://appleid.apple.com", aud="com.piks.app.native")
        apple = MagicMock()
        apple.exchange.return_value = (token, "encrypted-refresh")
        self.service.apple = apple
        self.service.clock = lambda: time.time() + 301
        with self.assertRaises(AuthError):
            self.service.provider_login("apple", token, challenge["id"], "ip1", "one-time-code")
        apple.exchange.assert_not_called()

    def testAppleDeletionRevokesProviderTokenAndRemovesTheIdentity(self):
        challenge = self.service.challenge("apple", "ip1")
        nonce = hashlib.sha256(challenge["nonce"].encode()).hexdigest()
        token = self.token(nonce, iss="https://appleid.apple.com", aud="com.piks.app.native")
        apple = MagicMock()
        apple.exchange.return_value = (token, "encrypted-refresh")
        self.service.apple = apple
        session = self.service.provider_login("apple", token, challenge["id"], "ip1", "one-time-code")
        self.service.delete(session["accessToken"])
        apple.revoke.assert_called_once_with("encrypted-refresh")
        with self.service.transaction() as db:
            self.assertEqual(db.execute("select count(*) from identities").fetchone()[0], 0)


if __name__ == "__main__": unittest.main()
