"""Device-independent identities and revocable opaque sessions; never stores media."""
import contextlib
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import time
import uuid


class AuthError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


class AuthService:
    def __init__(self, database, *, mailer, secret, clock=time.time, providers=None, apple=None):
        if len(secret) < 32:
            raise ValueError("AUTH_SECRET must contain at least 32 random bytes")
        self.database, self.mailer, self.secret, self.clock = str(database), mailer, secret, clock
        self.providers, self.apple = providers, apple
        with self.transaction() as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS users(
                id TEXT PRIMARY KEY,email TEXT,password TEXT,verified INTEGER NOT NULL DEFAULT 0,created REAL NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS email_accounts ON users(email) WHERE password IS NOT NULL;
            CREATE TABLE IF NOT EXISTS email_codes(
                email TEXT NOT NULL,purpose TEXT NOT NULL,hash TEXT NOT NULL,expires REAL NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,
                proof_hash TEXT,PRIMARY KEY(email,purpose));
            CREATE TABLE IF NOT EXISTS sessions(
                id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,family TEXT NOT NULL,
                access_hash TEXT NOT NULL UNIQUE,refresh_hash TEXT NOT NULL UNIQUE,access_until REAL NOT NULL,
                refresh_until REAL NOT NULL,used INTEGER NOT NULL DEFAULT 0,revoked INTEGER NOT NULL DEFAULT 0,auth_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS sessions_family ON sessions(family);
            CREATE TABLE IF NOT EXISTS rate_limits(key TEXT PRIMARY KEY,window REAL NOT NULL,count INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS identities(
                provider TEXT NOT NULL,subject TEXT NOT NULL,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                apple_refresh TEXT,PRIMARY KEY(provider,subject));
            CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY,provider TEXT NOT NULL,nonce_hash TEXT NOT NULL,expires REAL NOT NULL);
            """)

    @contextlib.contextmanager
    def transaction(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA secure_delete=ON")
        db.execute("BEGIN IMMEDIATE")
        try:
            yield db
            db.commit()
        except AuthError:
            # Rate-limit counters, failed-code attempts and replay revocations survive rejection.
            db.commit()
            raise
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def digest(self, kind, value):
        return hmac.new(self.secret, (kind + ":" + value).encode(), hashlib.sha256).hexdigest()

    @staticmethod
    def email(value):
        if not isinstance(value, str) or len(value) > 254:
            raise AuthError(400, "Укажите корректную почту.")
        value = value.strip().casefold()
        if not re.fullmatch(r"[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+", value):
            raise AuthError(400, "Укажите корректную почту.")
        return value

    @staticmethod
    def password(value):
        if not isinstance(value, str) or not 10 <= len(value) <= 1024:
            raise AuthError(400, "Пароль должен содержать от 10 до 1024 символов.")
        salt = os.urandom(16)
        hashed = hashlib.scrypt(value.encode(), salt=salt, n=32768, r=8, p=3, maxmem=64 * 1024 * 1024)
        return "scrypt$" + salt.hex() + "$" + hashed.hex()

    @staticmethod
    def matches(password, stored):
        if not isinstance(password, str) or len(password) > 1024:
            return False
        try:
            _, salt, expected = stored.split("$")
            actual = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=32768, r=8, p=3, maxmem=64 * 1024 * 1024)
            return hmac.compare_digest(actual.hex(), expected)
        except (ValueError, TypeError):
            return False

    def rate(self, db, scope, subject, peer, limit=8, seconds=300):
        now = self.clock()
        for namespace, value, maximum in [("subject", subject, limit), ("peer", peer, limit * 4)]:
            key = self.digest("rate", scope + ":" + namespace + ":" + value)
            row = db.execute("SELECT window,count FROM rate_limits WHERE key=?", (key,)).fetchone()
            count = row["count"] + 1 if row and now - row["window"] < seconds else 1
            window = row["window"] if row and now - row["window"] < seconds else now
            db.execute("INSERT OR REPLACE INTO rate_limits VALUES(?,?,?)", (key, window, count))
            if count > maximum:
                raise AuthError(429, "Слишком много попыток. Попробуйте позже.")

    def code(self, db, email, purpose, proof=None):
        code = f"{secrets.randbelow(1_000_000):06d}"
        # Transport failure must not leave a newly registered unusable account.
        try:
            self.mailer(email, code, purpose)
        except Exception:
            raise AuthError(503, "Отправка писем временно недоступна. Попробуйте позже.") from None
        db.execute("INSERT OR REPLACE INTO email_codes VALUES(?,?,?,?,0,?)",
                   (email, purpose, self.digest("code", email + ":" + purpose + ":" + code), self.clock() + 600,
                    self.digest("registration", proof) if proof else None))

    def consume_code(self, db, email, value, purpose):
        row = db.execute("SELECT * FROM email_codes WHERE email=? AND purpose=?", (email, purpose)).fetchone()
        if not row or row["expires"] <= self.clock() or row["attempts"] >= 5:
            raise AuthError(401, "Код неверен или истёк. Запросите новый код.")
        db.execute("UPDATE email_codes SET attempts=attempts+1 WHERE email=? AND purpose=?", (email, purpose))
        supplied = self.digest("code", email + ":" + purpose + ":" + str(value)[:100])
        if not hmac.compare_digest(row["hash"], supplied):
            raise AuthError(401, "Код неверен или истёк. Запросите новый код.")
        db.execute("DELETE FROM email_codes WHERE email=? AND purpose=?", (email, purpose))

    def register(self, email, password, peer):
        email = self.email(email)
        with self.transaction() as db:
            self.rate(db, "register", email, peer, limit=3, seconds=600)
            user = db.execute("SELECT * FROM users WHERE email=? AND password IS NOT NULL", (email,)).fetchone()
            if user and user["verified"]:
                return {"sent": True, "registrationId": secrets.token_urlsafe(32)}
            hashed = self.password(password)
            proof = secrets.token_urlsafe(32)
            self.code(db, email, "verify", proof=proof)
            if user:
                db.execute("UPDATE users SET password=? WHERE id=?", (hashed, user["id"]))
            else:
                db.execute("INSERT INTO users VALUES(?,?,?,0,?)", (str(uuid.uuid4()), email, hashed, self.clock()))
        return {"sent": True, "registrationId": proof}

    def verify_email(self, email, code, peer, registration_id):
        email = self.email(email)
        with self.transaction() as db:
            self.rate(db, "verify", email, peer, limit=10)
            pending = db.execute("SELECT proof_hash FROM email_codes WHERE email=? AND purpose='verify'", (email,)).fetchone()
            if not isinstance(registration_id, str) or len(registration_id) > 100 or not pending or not pending["proof_hash"] or not hmac.compare_digest(
                    pending["proof_hash"], self.digest("registration", registration_id)):
                raise AuthError(401, "Код относится к другой регистрации. Запросите новый код.")
            self.consume_code(db, email, code, "verify")
            user = db.execute("SELECT * FROM users WHERE email=? AND password IS NOT NULL", (email,)).fetchone()
            if not user:
                raise AuthError(401, "Код неверен или истёк.")
            db.execute("UPDATE users SET verified=1 WHERE id=?", (user["id"],))
            return self.issue(db, user["id"])

    def login(self, email, password, peer):
        email = self.email(email)
        with self.transaction() as db:
            self.rate(db, "login", email, peer)
            user = db.execute("SELECT * FROM users WHERE email=? AND password IS NOT NULL", (email,)).fetchone()
            # Same expensive computation and public error for unknown and unverified users.
            stored = user["password"] if user else "scrypt$" + "00" * 16 + "$" + "00" * 64
            valid = self.matches(password, stored)
            if not user or not user["verified"] or not valid:
                raise AuthError(401, "Почта или пароль неверны. Убедитесь, что почта подтверждена.")
            return self.issue(db, user["id"])

    def issue(self, db, user_id, family=None, auth_at=None):
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
        now = self.clock()
        db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,0,0,?)",
                   (str(uuid.uuid4()), user_id, family or str(uuid.uuid4()), self.digest("access", access),
                    self.digest("refresh", refresh), now + 900, now + 30 * 86400, auth_at or now))
        user = db.execute("SELECT id,email FROM users WHERE id=?", (user_id,)).fetchone()
        return {"user": dict(user), "accessToken": access, "refreshToken": refresh, "expiresAt": now + 900}

    def refresh(self, value, peer):
        if not isinstance(value, str) or len(value) > 1024:
            raise AuthError(401, "Сессия истекла. Войдите заново.")
        with self.transaction() as db:
            self.rate(db, "refresh", self.digest("refresh", value), peer, limit=12)
            row = db.execute("SELECT * FROM sessions WHERE refresh_hash=?", (self.digest("refresh", value),)).fetchone()
            if row and row["used"]:
                db.execute("UPDATE sessions SET revoked=1 WHERE family=?", (row["family"],))
                raise AuthError(401, "Сессия отозвана. Войдите заново.")
            if not row or row["revoked"] or row["refresh_until"] <= self.clock():
                raise AuthError(401, "Сессия истекла. Войдите заново.")
            db.execute("UPDATE sessions SET used=1 WHERE id=?", (row["id"],))
            return self.issue(db, row["user_id"], family=row["family"], auth_at=row["auth_at"])

    def session(self, db, access):
        if not isinstance(access, str) or len(access) > 1024:
            raise AuthError(401, "Войдите в аккаунт.")
        row = db.execute("SELECT * FROM sessions WHERE access_hash=?", (self.digest("access", access),)).fetchone()
        if not row or row["revoked"] or row["used"] or row["access_until"] <= self.clock():
            raise AuthError(401, "Сессия истекла. Войдите заново.")
        return row

    def me(self, access):
        with self.transaction() as db:
            session = self.session(db, access)
            return dict(db.execute("SELECT id,email FROM users WHERE id=?", (session["user_id"],)).fetchone())

    def logout(self, access):
        with self.transaction() as db:
            session = self.session(db, access)
            db.execute("UPDATE sessions SET revoked=1 WHERE family=?", (session["family"],))
        return {"ok": True}

    def delete(self, access):
        with self.transaction() as db:
            session = self.session(db, access)
            if self.clock() - session["auth_at"] > 600:
                raise AuthError(403, "Для удаления аккаунта войдите заново.")
            identities = db.execute("SELECT * FROM identities WHERE user_id=?", (session["user_id"],)).fetchall()
            for identity in identities:
                if identity["provider"] == "apple" and identity["apple_refresh"]:
                    if not self.apple:
                        raise AuthError(503, "Отзыв Apple-сессии временно недоступен.")
                    self.apple.revoke(identity["apple_refresh"])
            user = db.execute("SELECT email FROM users WHERE id=?", (session["user_id"],)).fetchone()
            db.execute("DELETE FROM email_codes WHERE email=?", (user["email"],))
            db.execute("DELETE FROM users WHERE id=?", (session["user_id"],))
        return {"ok": True}

    def request_reset(self, email, peer):
        email = self.email(email)
        with self.transaction() as db:
            self.rate(db, "reset", email, peer, limit=3, seconds=600)
            if db.execute("SELECT 1 FROM users WHERE email=? AND password IS NOT NULL AND verified=1", (email,)).fetchone():
                self.code(db, email, "reset")
        return {"sent": True}

    def reset_password(self, email, code, password, peer):
        email = self.email(email)
        with self.transaction() as db:
            self.rate(db, "reset-confirm", email, peer)
            hashed = self.password(password)
            self.consume_code(db, email, code, "reset")
            user = db.execute("SELECT id FROM users WHERE email=? AND password IS NOT NULL AND verified=1", (email,)).fetchone()
            if not user:
                raise AuthError(401, "Код неверен или истёк.")
            db.execute("UPDATE users SET password=? WHERE id=?", (hashed, user["id"]))
            db.execute("DELETE FROM sessions WHERE user_id=?", (user["id"],))
        return {"ok": True}

    def cleanup(self):
        with self.transaction() as db:
            now = self.clock()
            db.execute("DELETE FROM sessions WHERE refresh_until<?", (now,))
            db.execute("DELETE FROM challenges WHERE expires<?", (now,))
            db.execute("DELETE FROM email_codes WHERE expires<?", (now,))
            db.execute("DELETE FROM rate_limits WHERE window<?", (now - 86400,))

    def challenge(self, provider, peer):
        if not self.providers or not self.providers.enabled(provider):
            raise AuthError(400, "Этот способ входа недоступен.")
        nonce, identifier = secrets.token_urlsafe(32), str(uuid.uuid4())
        with self.transaction() as db:
            self.rate(db, "challenge", peer, peer, limit=24)
            db.execute("INSERT INTO challenges VALUES(?,?,?,?)", (identifier, provider,
                       hashlib.sha256(nonce.encode()).hexdigest(), self.clock() + 300))
        return {"id": identifier, "nonce": nonce}

    def provider_login(self, provider, token, challenge_id, peer, authorization_code=None):
        if not self.providers or not self.providers.enabled(provider):
            raise AuthError(400, "Этот способ входа недоступен.")
        with self.transaction() as db:
            self.rate(db, "provider", peer, peer, limit=24)
        claims = self.providers.verify(provider, token)
        nonce = claims["nonce"]
        checked_nonce = nonce if provider == "apple" else hashlib.sha256(nonce.encode()).hexdigest()
        # Bind and consume the challenge before any one-time Apple code exchange.
        # Concurrent/replayed requests cannot spend the same authorization code twice.
        with self.transaction() as db:
            challenge = db.execute("SELECT * FROM challenges WHERE id=?", (challenge_id,)).fetchone()
            if not challenge or challenge["provider"] != provider or challenge["expires"] <= self.clock() or not hmac.compare_digest(
                    challenge["nonce_hash"], checked_nonce):
                raise AuthError(401, "Запрос входа истёк. Повторите авторизацию.")
            db.execute("DELETE FROM challenges WHERE id=?", (challenge_id,))
        apple_refresh = None
        if provider == "apple":
            if not self.apple:
                raise AuthError(503, "Вход через Apple временно недоступен.")
            exchanged, apple_refresh = self.apple.exchange(authorization_code)
            exchanged_claims = self.providers.verify("apple", exchanged)
            if exchanged_claims["sub"] != claims["sub"] or exchanged_claims["nonce"] != claims["nonce"]:
                raise AuthError(401, "Не удалось подтвердить вход Apple.")
        with self.transaction() as db:
            identity = db.execute("SELECT * FROM identities WHERE provider=? AND subject=?", (provider, claims["sub"])).fetchone()
            if identity:
                user_id = identity["user_id"]
                if apple_refresh:
                    db.execute("UPDATE identities SET apple_refresh=? WHERE provider=? AND subject=?", (apple_refresh, provider, claims["sub"]))
            else:
                user_id = str(uuid.uuid4())
                email = self.email(claims["email"]) if claims.get("email") else None
                db.execute("INSERT INTO users VALUES(?,?,NULL,1,?)", (user_id, email, self.clock()))
                db.execute("INSERT INTO identities VALUES(?,?,?,?)", (provider, claims["sub"], user_id, apple_refresh))
            return self.issue(db, user_id)
