"""Small WSGI identity API; production is served by Gunicorn behind the owner's Nginx."""
import http
import json
from backend.auth import AuthError


class IdentityAPI:
    def __init__(self, service, *, email_enabled=False, google_client_id=None, google_server_client_id=None):
        self.service, self.email_enabled = service, email_enabled
        self.google_client_id, self.google_server_client_id = google_client_id, google_server_client_id

    def __call__(self, environ, start_response):
        try:
            result = self.dispatch(environ)
            status = 200
        except AuthError as error:
            status, result = error.status, {"error": error.message}
        except (ValueError, TypeError, KeyError, UnicodeDecodeError):
            status, result = 400, {"error": "Проверьте введённые данные."}
        except Exception:
            status, result = 503, {"error": "Сервис временно недоступен. Попробуйте позже."}
        body = json.dumps(result, ensure_ascii=False).encode()
        start_response(f"{status} {http.HTTPStatus(status).phrase}", [
            ("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(body))),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")])
        return [body]

    def dispatch(self, environ):
        path, method = environ.get("PATH_INFO", ""), environ.get("REQUEST_METHOD", "GET")
        if environ.get("HTTP_ORIGIN"):
            raise AuthError(403, "Запрос из браузера не поддерживается.")
        peer = environ.get("REMOTE_ADDR", "unknown")
        if peer in ("127.0.0.1", "::1") and environ.get("HTTP_X_PIKS_CLIENT_IP"):
            peer = environ["HTTP_X_PIKS_CLIENT_IP"][:100]
        header = environ.get("HTTP_AUTHORIZATION", "")
        access = header[7:] if header.startswith("Bearer ") else ""
        if method == "GET":
            if path == "/health": return {"ok": True}
            if path == "/v1/me": return self.service.me(access)
            if path == "/v1/capabilities":
                verifier = self.service.providers
                apple = bool(verifier and verifier.enabled("apple") and self.service.apple)
                return {"apple": apple, "google": bool(apple and verifier.enabled("google") and self.google_client_id),
                        "email": self.email_enabled, "googleClientId": self.google_client_id,
                        "googleServerClientId": self.google_server_client_id}
            raise AuthError(404, "Адрес не найден.")
        if method != "POST": raise AuthError(405, "Метод не поддерживается.")
        routes = {"/v1/auth/register", "/v1/auth/verify-email", "/v1/auth/login", "/v1/auth/reset-request",
                  "/v1/auth/reset-confirm", "/v1/auth/challenge", "/v1/auth/provider", "/v1/auth/refresh",
                  "/v1/auth/logout", "/v1/account/delete"}
        if path not in routes: raise AuthError(404, "Адрес не найден.")
        length = int(environ.get("CONTENT_LENGTH") or "0")
        if length < 0 or length > 16384: raise AuthError(413, "Запрос слишком большой.")
        if environ.get("CONTENT_TYPE", "").split(";")[0] != "application/json":
            raise AuthError(415, "Используйте JSON.")
        body = json.loads(environ["wsgi.input"].read(length) or b"{}")
        if not isinstance(body, dict) or any(not isinstance(v, (str, type(None))) for v in body.values()):
            raise AuthError(400, "Проверьте введённые данные.")
        if path in ("/v1/auth/register", "/v1/auth/verify-email", "/v1/auth/reset-request", "/v1/auth/reset-confirm") and not self.email_enabled:
            raise AuthError(503, "Вход по почте временно недоступен.")
        if path == "/v1/auth/register": return self.service.register(body["email"], body["password"], peer)
        if path == "/v1/auth/verify-email": return self.service.verify_email(body["email"], body["code"], peer, body["registrationId"])
        if path == "/v1/auth/login": return self.service.login(body["email"], body["password"], peer)
        if path == "/v1/auth/reset-request": return self.service.request_reset(body["email"], peer)
        if path == "/v1/auth/reset-confirm": return self.service.reset_password(body["email"], body["code"], body["password"], peer)
        if path == "/v1/auth/challenge": return self.service.challenge(body["provider"], peer)
        if path == "/v1/auth/provider": return self.service.provider_login(body["provider"], body["idToken"], body["challengeId"], peer, body.get("authorizationCode"))
        if path == "/v1/auth/refresh": return self.service.refresh(body["refreshToken"], peer)
        if path == "/v1/auth/logout": return self.service.logout(access)
        if path == "/v1/account/delete": return self.service.delete(access)
        raise AuthError(404, "Адрес не найден.")
