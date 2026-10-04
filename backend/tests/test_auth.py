import pathlib
import contextlib
import sqlite3
import tempfile
import unittest
from backend.auth import AuthService, AuthError


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.sent = []
        self.time = 1_000_000.0
        self.service = AuthService(pathlib.Path(self.folder.name) / "users.sqlite", mailer=lambda *args: self.sent.append(args),
                                   clock=lambda: self.time, secret=b"local-unit-test-secret-32-bytes-minimum")

    def tearDown(self):
        self.folder.cleanup()

    def registered(self, email="owner@example.test"):
        registration = self.service.register(email, "a strong unique test password", "ip1")
        return self.service.verify_email(email, self.sent[-1][1], "ip1", registration["registrationId"])

    def testNoSessionBeforeEmailIsVerified(self):
        registration = self.service.register("me@example.test", "a strong unique test password", "ip1")
        with self.assertRaises(AuthError):
            self.service.login("me@example.test", "a strong unique test password", "ip1")
        result = self.service.verify_email("me@example.test", self.sent[-1][1], "ip1", registration["registrationId"])
        self.assertEqual(self.service.me(result["accessToken"])["email"], "me@example.test")

    def testVerificationCodeIsSingleUseAndExpires(self):
        registration = self.service.register("me@example.test", "a strong unique test password", "ip1")
        code = self.sent[-1][1]
        self.time += 601
        with self.assertRaises(AuthError): self.service.verify_email("me@example.test", code, "ip1", registration["registrationId"])

    def testWrongCodeHasLimitedAttempts(self):
        registration = self.service.register("me@example.test", "a strong unique test password", "ip1")
        for _ in range(5):
            with self.assertRaises(AuthError): self.service.verify_email("me@example.test", "wrong", "ip1", registration["registrationId"])
        with self.assertRaises(AuthError): self.service.verify_email("me@example.test", self.sent[-1][1], "ip1", registration["registrationId"])

    def testRefreshRotationRejectsReplayAndRevokesItsFamily(self):
        first = self.registered()
        second = self.service.refresh(first["refreshToken"], "ip1")
        with self.assertRaises(AuthError): self.service.refresh(first["refreshToken"], "ip1")
        with self.assertRaises(AuthError): self.service.me(second["accessToken"])
        with self.assertRaises(AuthError): self.service.refresh(second["refreshToken"], "ip1")

    def testAccessTokenExpires(self):
        session = self.registered()
        self.time += 901
        with self.assertRaises(AuthError): self.service.me(session["accessToken"])
        self.assertIn("accessToken", self.service.refresh(session["refreshToken"], "ip1"))

    def testDeleteRevokesSessionsAndRemovesPersonalData(self):
        session = self.registered()
        self.service.delete(session["accessToken"])
        with self.assertRaises(AuthError): self.service.me(session["accessToken"])
        with self.assertRaises(AuthError): self.service.refresh(session["refreshToken"], "ip1")
        with contextlib.closing(sqlite3.connect(self.service.database)) as db:
            self.assertEqual(db.execute("select count(*) from users").fetchone()[0], 0)

    def testStoredDatabaseDoesNotContainPasswordsCodesOrTokens(self):
        session = self.registered()
        data = pathlib.Path(self.service.database).read_bytes()
        for value in ["a strong unique test password", self.sent[-1][1], session["accessToken"], session["refreshToken"]]:
            self.assertNotIn(value.encode(), data)

    def testLoginRateLimitAndGenericFailure(self):
        errors = []
        for _ in range(9):
            try: self.service.login("missing@example.test", "wrong password", "ip1")
            except AuthError as e: errors.append(e.status)
        self.assertIn(429, errors)
        with self.assertRaises(AuthError) as error:
            self.service.login("another@example.test", "wrong password", "ip2")
        self.assertEqual(error.exception.status, 401)

    def testResetRequiresProofAndRevokesExistingSessions(self):
        old = self.registered()
        self.service.request_reset("owner@example.test", "ip1")
        self.service.reset_password("owner@example.test", self.sent[-1][1], "new password that is unique", "ip1")
        with self.assertRaises(AuthError): self.service.me(old["accessToken"])
        with self.assertRaises(AuthError): self.service.login("owner@example.test", "a strong unique test password", "ip1")
        self.assertIn("accessToken", self.service.login("owner@example.test", "new password that is unique", "ip1"))

    def testVerifiedEmailCannotBeTakenOverByRegisteringAgain(self):
        session = self.registered()
        self.service.register("owner@example.test", "an attacker supplied password", "ip2")
        self.assertEqual(self.service.me(session["accessToken"])["email"], "owner@example.test")
        with self.assertRaises(AuthError): self.service.login("owner@example.test", "an attacker supplied password", "ip2")

    def testEmailFailureDoesNotCreateAnUnusableAccount(self):
        def unavailable(*args): raise RuntimeError("SMTP unavailable")
        self.service.mailer = unavailable
        with self.assertRaises(AuthError) as error: self.service.register("me@example.test", "strong enough password", "ip1")
        self.assertEqual(error.exception.status, 503)
        with contextlib.closing(sqlite3.connect(self.service.database)) as db:
            self.assertEqual(db.execute("select count(*) from users").fetchone()[0], 0)

    def testConcurrentSignupCannotActivateAttackerPassword(self):
        owner = self.service.register("me@example.test", "owners intended password", "ip1")
        attacker = self.service.register("me@example.test", "attackers chosen password", "ip2")
        with self.assertRaises(AuthError):
            self.service.verify_email("me@example.test", self.sent[-1][1], "ip1", owner["registrationId"])
        replacement = self.service.register("me@example.test", "owners intended password", "ip1")
        self.service.verify_email("me@example.test", self.sent[-1][1], "ip1", replacement["registrationId"])
        with self.assertRaises(AuthError): self.service.login("me@example.test", "attackers chosen password", "ip2")
        self.assertIn("accessToken", self.service.login("me@example.test", "owners intended password", "ip1"))


if __name__ == "__main__": unittest.main()
