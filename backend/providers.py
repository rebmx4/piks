"""Provider token validation using maintained cryptographic libraries and fixed JWKS URLs."""
import base64
import hashlib
import json
import time
import urllib.parse
import urllib.request
import jwt
from cryptography.fernet import Fernet
from backend.auth import AuthError


class ProviderVerifier:
    def __init__(self, *, apple_audience, google_audiences, key_clients=None):
        self.audiences = {"apple": [apple_audience] if apple_audience else [], "google": google_audiences}
        self.issuers = {"apple": ["https://appleid.apple.com"], "google": ["https://accounts.google.com", "accounts.google.com"]}
        self.keys = key_clients or {
            "apple": jwt.PyJWKClient("https://appleid.apple.com/auth/keys", lifespan=900, timeout=5),
            "google": jwt.PyJWKClient("https://www.googleapis.com/oauth2/v3/certs", lifespan=900, timeout=5)}

    def enabled(self, provider): return bool(self.audiences.get(provider))

    def verify(self, provider, token):
        if not self.enabled(provider) or not isinstance(token, str) or len(token) > 8192:
            raise AuthError(401, "Не удалось подтвердить вход.")
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256":
                raise ValueError("Unsupported provider algorithm")
            key = self.keys[provider].get_signing_key_from_jwt(token).key
            claims = jwt.decode(token, key, algorithms=["RS256"], audience=self.audiences[provider],
                                issuer=self.issuers[provider], leeway=30,
                                options={"require": ["exp", "iat", "iss", "aud", "sub", "nonce"]})
            if not isinstance(claims["sub"], str) or not 1 <= len(claims["sub"]) <= 255:
                raise ValueError("Invalid subject")
            if not isinstance(claims["nonce"], str) or len(claims["nonce"]) > 256:
                raise ValueError("Invalid nonce")
            # Apple can omit email on later authorizations; its signed subject is sufficient.
            if provider == "google" and (not claims.get("email") or claims.get("email_verified") is not True):
                raise ValueError("Unverified provider email")
            if provider == "apple" and claims.get("email") and claims.get("email_verified") not in (True, "true"):
                raise ValueError("Unverified provider email")
            return claims
        except (jwt.PyJWTError, ValueError, TypeError, KeyError, OSError):
            raise AuthError(401, "Не удалось подтвердить вход. Повторите авторизацию.") from None


class AppleClient:
    def __init__(self, *, client_id, team_id, key_id, private_key, encryption_secret):
        self.client_id, self.team_id, self.key_id, self.private_key = client_id, team_id, key_id, private_key
        self.cipher = Fernet(base64.urlsafe_b64encode(hashlib.sha256(b"piks-apple-token-encryption\0" + encryption_secret).digest()))

    def client_secret(self):
        now = int(time.time())
        return jwt.encode({"iss": self.team_id, "iat": now, "exp": now + 300,
                           "aud": "https://appleid.apple.com", "sub": self.client_id},
                          self.private_key, algorithm="ES256", headers={"kid": self.key_id})

    def post(self, path, fields):
        fields.update(client_id=self.client_id, client_secret=self.client_secret())
        req = urllib.request.Request("https://appleid.apple.com/auth/" + path,
                                     data=urllib.parse.urlencode(fields).encode(), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                data = response.read()
                return json.loads(data) if data else {}
        except (OSError, ValueError):
            raise AuthError(503, "Сервис Apple временно недоступен. Попробуйте позже.") from None

    def exchange(self, code):
        if not isinstance(code, str) or not 1 <= len(code) <= 4096:
            raise AuthError(400, "Повторите вход через Apple.")
        response = self.post("token", {"grant_type": "authorization_code", "code": code})
        if not response.get("refresh_token") or not response.get("id_token"):
            raise AuthError(401, "Повторите вход через Apple.")
        return response["id_token"], self.cipher.encrypt(response["refresh_token"].encode()).decode()

    def revoke(self, encrypted):
        try:
            refresh = self.cipher.decrypt(encrypted.encode()).decode()
        except Exception:
            raise AuthError(503, "Не удалось отозвать сессию Apple.") from None
        self.post("revoke", {"token": refresh, "token_type_hint": "refresh_token"})
