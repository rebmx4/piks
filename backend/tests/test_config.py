import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
from backend.config import create_app, SMTPMailer


class ConfigTests(unittest.TestCase):
    def testMissingSecretCannotStartAService(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                create_app({"database": str(Path(folder) / "accounts.sqlite"), "secretFile": str(Path(folder) / "missing")})

    def testServiceWithoutSMTPKeepsAllUnavailableProvidersDisabled(self):
        with tempfile.TemporaryDirectory() as folder:
            secret = Path(folder) / "key"
            secret.write_bytes(b"configuration-test-secret-long-enough")
            api = create_app({"database": str(Path(folder) / "accounts.sqlite"), "secretFile": str(secret)})
            response = b"".join(api({"PATH_INFO": "/v1/capabilities", "REQUEST_METHOD": "GET"}, lambda *_: None))
            caps = json.loads(response)
            self.assertFalse(caps["email"])
            self.assertFalse(caps["apple"])
            self.assertFalse(caps["google"])

    def testSMTPUsesVerifiedTLSBeforeAuthenticationAndNeverLogsCredentials(self):
        options = {"host": "mail.example.test", "port": 587, "mode": "starttls", "sender": "noreply@example.test",
                   "username": "mail-user", "password": "mail-private-password"}
        transport = MagicMock()
        with patch("backend.config.smtplib.SMTP", return_value=transport) as connect:
            SMTPMailer(options)("recipient@example.test", "123456", "verify")
        connect.assert_called_once_with("mail.example.test", 587, timeout=8)
        names = [call[0] for call in transport.method_calls]
        self.assertLess(names.index("starttls"), names.index("login"))
        sent = transport.send_message.call_args.args[0]
        self.assertEqual(sent["To"], "recipient@example.test")
        self.assertIn("123456", sent.get_content())
        self.assertNotIn("mail-private-password", sent.as_string())

    def testInsecureSMTPAndHeaderInjectionAreRejected(self):
        for config in [dict(host="mail.example.test", sender="me@example.test", mode="plain"),
                       dict(host="mail.example.test", sender="me@example.test\r\nBcc: thief@example.test", mode="ssl")]:
            with self.assertRaises(ValueError): SMTPMailer(config)


if __name__ == "__main__": unittest.main()
