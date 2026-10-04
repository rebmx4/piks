# APIKS identity

Собственный сервис аккаунтов. Проекты и медиа не передаются на сервер;
эндпоинтов загрузки/хранения видео или проектов нет. SQLite хранит только
пользователей, идентификаторы Apple/Google, хеши сессий/кодов и ограничения запросов.
Пароли хешируются scrypt. Apple refresh token шифруется для последующего отзыва.

Проверка: `backend/.venv/Scripts/python.exe -m unittest discover -s backend/tests -v`.
На сервере: `python -m unittest discover -s backend/tests -v` в окружении release.
Развёртывание: `python backend/deploy.py`. Предварительный просмотр: `--dry-run`.
Создаётся отдельный systemd-сервис `piks-auth`, пользователь, каталог, localhost-порт
8816 и HTTPS-маршрут `https://rynpro.ru/piks-auth/`. Перед активацией выполняются
тесты, проверка Nginx и health check; при ошибке возвращается предыдущий релиз.
Файлы и маршруты редакторов `/ryn/` и `/ryn-next/` не изменяются.

Приватная конфигурация: `/etc/piks-native/config.json`, root:piks-auth, 0640.
Постоянный случайный ключ: `/etc/piks-native/auth.key`. Его нельзя выводить в логи,
коммитить, случайно заменять или терять: он защищает сессии и Apple refresh tokens.
Резервные копии данных аккаунтов и ключа организует владелец сервера отдельно.

Публичные параметры Google/Apple и почтовый транспорт добавляются в конфигурацию:

```json
{
  "database": "/var/lib/piks-auth/accounts.sqlite",
  "secretFile": "/etc/piks-native/auth.key",
  "apple": {
    "clientId": "com.piks.app.native",
    "teamId": "GR3WB4Z646",
    "keyId": "KEY_ID_FROM_APPLE",
    "privateKeyFile": "/etc/piks-native/apple-signin.p8"
  },
  "google": {"clientId": "IOS_CLIENT_ID_FROM_GOOGLE.apps.googleusercontent.com"},
  "smtp": {
    "host": "MAIL_HOST", "port": 465, "mode": "ssl",
    "sender": "SENDER_ADDRESS", "username": "SMTP_USER", "password": "PRIVATE_SMTP_PASSWORD"
  }
}
```

Без настроенного SMTP регистрация по почте выключена. Без ключа Apple вход Apple
и Google не предлагается: эквивалентный вход Apple должен быть доступен вместе с Google.
Секреты провайдеров передаются в приватные файлы вне репозитория.
После изменения: `systemctl restart piks-auth`; проверка `/v1/capabilities`.

Нативный Google OAuth использует PKCE и ASWebAuthenticationSession по документации
Google для установленного iOS-приложения. Требуется iOS OAuth client с новым bundle ID;
его обратный ID указывается в `GOOGLE_REVERSED_CLIENT_ID` нативной Xcode-конфигурации.
Секрет web OAuth client не нужен. Проверяются подпись JWT, issuer, audience,
подтверждение почты и одноразовый nonce. Автоматического объединения аккаунтов
по совпадающей почте нет. Перед релизом обязательна реальная проверка обоих провайдеров.

Сессии: access 15 минут, refresh 30 дней с ротацией; повторное использование refresh
отзывает семейство сессий. Удаление требует входа за последние 10 минут и отзыва Apple.
Письма: шестизначный код, 10 минут, пять попыток; привязка к конкретной регистрации.
Клиент не повторяет автоматически запрос обмена одноразового Apple-кода.
