"""Private service configuration and encrypted SMTP transport; never prints secrets."""
import json
import os
import re
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path
from backend.api import IdentityAPI
from backend.auth import AuthService
from backend.providers import AppleClient, ProviderVerifier


class SMTPMailer:
    def __init__(self, config):
        self.host = config["host"]
        self.mode = config.get("mode", "ssl")
        self.port = int(config.get("port", 465 if self.mode == "ssl" else 587))
        self.sender = config["sender"]
        self.username, self.password = config.get("username"), config.get("password")
        if self.mode not in ("ssl", "starttls") or not 1 <= self.port <= 65535:
            raise ValueError("SMTP requires TLS")
        if not isinstance(self.host, str) or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", self.host):
            raise ValueError("Invalid SMTP host")
        if not isinstance(self.sender, str) or any(c in self.sender for c in "\r\n"):
            raise ValueError("Invalid SMTP sender")
        self.sender = AuthService.email(self.sender)
        if bool(self.username) != bool(self.password):
            raise ValueError("Incomplete SMTP credentials")

    def __call__(self, recipient, code, purpose):
        recipient = AuthService.email(recipient)
        if purpose not in ("verify", "reset") or not re.fullmatch(r"\d{6}", code):
            raise ValueError("Invalid verification message")
        message = EmailMessage()
        message["From"] = "APIKS <" + self.sender + ">"
        message["To"] = recipient
        message["Subject"] = "Код подтверждения APIKS" if purpose == "verify" else "Восстановление доступа APIKS"
        message.set_content("Ваш код: " + code + "\n\nОн действует 10 минут. Никому его не сообщайте.\n"
                            "Если вы не запрашивали код, просто проигнорируйте это письмо.\n")
        context = ssl.create_default_context()
        if self.mode == "ssl":
            server = smtplib.SMTP_SSL(self.host, self.port, timeout=8, context=context)
        else:
            server = smtplib.SMTP(self.host, self.port, timeout=8)
        try:
            if self.mode == "starttls":
                server.ehlo(); server.starttls(context=context); server.ehlo()
            if self.username: server.login(self.username, self.password)
            server.send_message(message)
        finally:
            server.close()


def create_app(config):
    try:
        secret = Path(config["secretFile"]).read_bytes()
        if len(secret) < 32: raise ValueError("Invalid identity secret")
    except (OSError, KeyError):
        raise ValueError("Identity secret is missing") from None
    database = Path(config["database"])
    database.parent.mkdir(parents=True, exist_ok=True)
    smtp = config.get("smtp")
    email_enabled = bool(smtp and smtp.get("host"))
    mailer = SMTPMailer(smtp) if email_enabled else None
    apple_config = config.get("apple", {})
    apple_client = None
    if apple_config:
        try:
            apple_client = AppleClient(client_id=apple_config["clientId"], team_id=apple_config["teamId"],
                key_id=apple_config["keyId"], private_key=Path(apple_config["privateKeyFile"]).read_text(),
                encryption_secret=secret)
        except (KeyError, OSError):
            raise ValueError("Apple identity configuration is incomplete") from None
    google = config.get("google", {})
    audiences = list(filter(None, [google.get("serverClientId"), google.get("clientId")]))
    verifier = ProviderVerifier(apple_audience=apple_config.get("clientId"), google_audiences=audiences)
    service = AuthService(database, mailer=mailer, secret=secret, providers=verifier, apple=apple_client)
    service.cleanup()
    return IdentityAPI(service, email_enabled=email_enabled, google_client_id=google.get("clientId"),
                       google_server_client_id=google.get("serverClientId"))


def load_application():
    filename = os.environ.get("PIKS_AUTH_CONFIG", "/etc/piks-native/config.json")
    try:
        config = json.loads(Path(filename).read_text())
    except (OSError, ValueError):
        raise ValueError("Identity configuration is unavailable") from None
    return create_app(config)
