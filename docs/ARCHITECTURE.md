# Familygram — архитектура

Семейный мессенджер на десятки пользователей. Self-hosted, open source.
Цели: простой UI как в Telegram, iOS/Android/Web, звонки, голосовые, файлы,
устойчивость к блокировкам.

## Компоненты

```
 ┌────────────── клиенты (Flutter: iOS / Android / Web) ──────────────┐
 │  REST (JSON)  +  WebSocket (события)  +  WebRTC (звонки, этап 2)   │
 └───────────────────────────────┬────────────────────────────────────┘
                                 │  только TCP 443, TLS, ваш домен
                       ┌─────────▼─────────┐
                       │ Caddy (TLS, ACME) │   ← опционально: RU-релей перед ним
                       └─────────┬─────────┘
                ┌────────────────┼──────────────────┐
        ┌───────▼───────┐                  ┌────────▼────────┐
        │ familygram    │                  │ LiveKit + TURN  │  (этап 2)
        │ Go, 1 бинарник│                  │ TURN/TLS на 443 │
        │ SQLite + файлы│                  └─────────────────┘
        └───────────────┘
```

* **server/** — Go, один бинарник, без CGO. SQLite (`modernc.org/sqlite`),
  файлы на диске в `DATA_DIR/files`. Отдаёт API, WebSocket и собранный
  web-клиент. Нагрузка — десятки пользователей, поэтому без брокеров/кэшей.
* **app/** — Flutter, одна кодовая база для iOS, Android и Web.
  Адрес сервера вводится при входе → одно приложение в сторах работает с
  любым self-hosted сервером.
* **deploy/** — `docker compose` с Caddy (автоматический Let's Encrypt).

## Устойчивость к блокировкам

Гарантированно «неблокируемого» решения нет (белые списки на мобильном
интернете блокируют всё, кроме разрешённого), но мы делаем трафик
неотличимым от обычного сайта:

1. **Один порт 443, TLS, свой домен.** Сообщения — HTTPS + WebSocket по тому же
   пути, что и обычный сайт. На `/` отдаётся web-клиент — сервер выглядит как
   обычное веб-приложение.
2. **Нет узнаваемых протоколов.** Никакого XMPP/Matrix/MTProto, нестандартных
   портов, UDP-only протоколов. Голые WebRTC/STUN/UDP детектятся ТСПУ, поэтому
   звонки идут через **TURN поверх TLS на 443** (форсируем relay при
   неудаче прямого соединения).
3. **Релей в РФ.** Если блокируют IP зарубежного сервера — ставится дешёвый
   российский VPS с Caddy/nginx `stream` (SNI-proxy) на 443, который
   прозрачно проксирует на основной сервер. Клиенту меняется только адрес.
   Это же частично помогает при белых списках (если IP релея в них попадает).
4. **Несколько адресов сервера в клиенте** (этап 3): клиент перебирает
   зеркала (основной домен, релей, CDN-фронт) до первого рабочего.
5. **Push.** APNs/FCM зависят от Apple/Google; они содержат только «есть
   новое сообщение» без текста. На Android дополнительно — фоновое
   WebSocket-подключение как fallback (этап 3).

## Модель данных

| Таблица         | Поля                                                                 |
|-----------------|----------------------------------------------------------------------|
| users           | id, phone (E.164, unique), display_name, avatar_file_id, is_admin    |
| sessions        | token_hash, user_id, created_at, last_seen                           |
| allowed_phones  | phone, display_name, added_by, created_at (кому разрешён вход)       |
| sms_codes       | phone, code_hash, expires_at, attempts, sent_at                      |
| chats           | id, kind (`direct`/`group`), title, avatar_file_id, created_at       |
| chat_members    | chat_id, user_id, last_read_message_id                               |
| messages        | id, chat_id, sender_id, client_id, kind, text, file_id, reply_to_id, created_at, edited_at, deleted |
| files           | id, uploader_id, name, mime, size, width, height, duration_ms, path  |

`kind` сообщения: `text`, `image`, `video`, `file`, `voice`.
ID сообщений — монотонные int64 (пагинация `before=<id>`).
`client_id` — UUID от клиента для идемпотентной отправки и оптимистичного UI.

## API (v1)

Авторизация: `Authorization: Bearer <token>`; для `<img>`/WS — `?token=`.

| Метод  | Путь                              | Описание                                  |
|--------|-----------------------------------|-------------------------------------------|
| GET    | /api/info                         | имя сервера, способ входа                 |
| POST   | /api/auth/request-code            | `{phone}` → SMS с кодом                   |
| POST   | /api/auth/verify                  | `{phone,code}` → token, user, is_new      |
| POST   | /api/auth/logout                  |                                           |
| GET    | /api/me · PATCH /api/me           | профиль                                   |
| GET    | /api/users                        | все пользователи сервера (семья)          |
| GET/POST/DELETE | /api/phones[/{phone}]    | (админ) список разрешённых номеров        |
| GET    | /api/chats                        | чаты + последнее сообщение + непрочитанные|
| POST   | /api/chats                        | `{kind:"direct",user_id}` / `{kind:"group",title,member_ids}` |
| GET    | /api/chats/{id}/messages          | `?before=&limit=`                         |
| POST   | /api/chats/{id}/messages          | `{client_id,text,file_id,reply_to_id}`    |
| DELETE | /api/messages/{id}                | удалить своё сообщение                    |
| POST   | /api/chats/{id}/read              | `{message_id}`                            |
| POST   | /api/files                        | multipart `file` (+ width/height/duration)|
| GET    | /api/files/{id}                   | скачать (поддерживает Range)              |
| GET    | /api/ws                           | WebSocket событий                         |
| POST   | /api/devices                      | `{platform:"ios",token,sandbox,kind}` — телефон для push (`kind`: `alert` — сообщения, `voip` — входящие звонки); привязан к сессии, удаляется при выходе. Ответ `{ok, push}`: `push=false`, если на сервере нет ключа APNs |

События WebSocket (сервер → клиент): `message.new`, `message.deleted`,
`chat.new`, `chat.read`, `typing`. Клиент → сервер: `typing`, позже —
сигналинг звонков (`call.*`).

## Этапы

1. **MVP (текущий):** вход по номеру телефона + SMS-код, личные и групповые чаты, текст,
   фото, видео, файлы, голосовые, прочтения, web-клиент, docker-деплой.
2. **Звонки:** LiveKit (SFU) + встроенный TURN/TLS на 443, аудио/видео 1:1
   и групповые, CallKit/ConnectionService.
3. **Мобильная доставка и устойчивость:** APNs/FCM, список зеркал в клиенте,
   инструкция по RU-релею.
4. **E2EE** (опционально).

## Формат JSON (контракт сервер ↔ клиент)

Все поля в `snake_case`, время — unix-миллисекунды. Ошибки: HTTP-код + `{"error":"текст"}`.

```jsonc
// User
{"id":1,"phone":"+79991234567","display_name":"Мама","avatar_file_id":null,"is_admin":false}
// File
{"id":"9f2c…(32 hex)","name":"photo.jpg","mime":"image/jpeg","size":123456,"width":1280,"height":960,"duration_ms":0}
// Message (kind: text|image|video|file|voice)
{"id":42,"chat_id":3,"sender_id":1,"client_id":"uuid","kind":"image","text":"подпись",
 "file":File|null,"reply_to_id":null,"created_at":1731400000000,"deleted":false}
// Chat (для direct title = имя собеседника; для чата с собой — "Избранное")
{"id":3,"kind":"group","title":"Семья","avatar_file_id":null,"member_ids":[1,2,5],
 "last_message":Message|null,"unread":2,"last_read_id":40,"others_read_id":41}
```

* `GET /api/info` → `{"name":"Familygram","auth":"sms"}`
* `POST /api/auth/request-code` `{phone}` → `{"retry_after":60}`. Номер нормализуется в E.164
  (`8XXXXXXXXXX` → `+7XXXXXXXXXX`). 403 `{"error":"Этот номер не добавлен в семью"}`, если номера нет
  ни в `users`, ни в `allowed_phones`; 429 с `retry_after`, если код запрошен < 60 с назад.
* `POST /api/auth/verify` `{phone,code}` → `{"token","user","is_new":bool}`. Код 6 цифр, живёт 5 мин,
  5 попыток. Если пользователя ещё нет (номер из `allowed_phones`) — он создаётся, `display_name`
  берётся из `allowed_phones` (или равен номеру), `is_new=true` → клиент показывает шаг «Как вас зовут?»
  и сохраняет имя через `PATCH /api/me {display_name}`.
* `GET /api/phones` → `[{"phone","display_name","registered":bool}]`; `POST /api/phones` `{phone,display_name?}`;
  `DELETE /api/phones/{phone}` — только админ.
* `GET /api/users` → `[User]`; `GET /api/chats` → `[Chat]` (по последней активности)
* `POST /api/chats` → `Chat` (для direct — существующий, если уже есть)
* `GET /api/chats/{id}/messages?before=&limit=50` → `[Message]` по возрастанию id
* `POST /api/chats/{id}/messages` → `Message` (повтор `client_id` возвращает то же сообщение)
* `POST /api/files` multipart: `file` + необязательные `width`,`height`,`duration_ms` → `File`

WebSocket `/api/ws?token=…`, конверт `{"type":"…","data":{…}}`:
* сервер → клиент: `message.new` (Message), `message.deleted` `{chat_id,id}`,
  `chat.new` `{chat_id}`, `chat.read` `{chat_id,user_id,message_id}`, `typing` `{chat_id,user_id}`
* клиент → сервер: `typing` `{chat_id}`; пинг — WS ping каждые 25 с.

## Вход по SMS

* Первый админ: номер из `FG_ADMIN_PHONE` — разрешён всегда и при первом входе становится админом.
  Дальше админ добавляет номера семьи в приложении или командой `familygram add-phone +7999… "Имя"`.
* Посторонние номера не получают SMS (защита от SMS-флуда и трат). Лимиты: 1 код в 60 с на номер,
  10 запросов в час с одного IP.
* Провайдер SMS подключаемый, `FG_SMS_PROVIDER`:
  `log` (код пишется в лог сервера — для разработки и самых маленьких установок),
  `smsru` (`FG_SMSRU_API_ID`), `smsc` (`FG_SMSC_LOGIN`, `FG_SMSC_PASSWORD`),
  `twilio` (`FG_TWILIO_SID`, `FG_TWILIO_TOKEN`, `FG_TWILIO_FROM`). Текст: «Familygram: код 123456».
  Российские провайдеры (sms.ru, smsc.ru) надёжнее доставляют на номера РФ.

## Звонки (этап 2)

**Медиа — LiveKit** (open-source SFU на Go): аудио/видео 1:1 и групповые, SDK для
iOS/Android/Web (`livekit_client`). Familygram-сервер отвечает только за «звонок»
(вызов, принятие, отбой, история) и выдаёт клиентам JWT-токены LiveKit.

Транспорт медиа (LiveKit сам перебирает по порядку):
1. UDP 7882 (лучшее качество; часто режется ТСПУ);
2. TCP 7881;
3. **TURN поверх TLS на 443** (`turn.<домен>`) — выглядит как обычный HTTPS.
   В клиенте есть настройка «Звонки только через сервер» (`iceTransportPolicy: relay`).

Сигналинг LiveKit — `wss://rtc.<домен>` (через Caddy). TLS на 443 делится по SNI
модулем `caddy-l4`: `<домен>` и `rtc.<домен>` → HTTP, `turn.<домен>` → TURN LiveKit
(`external_tls: true`, TLS терминирует Caddy).

Конфиг сервера: `FG_LIVEKIT_URL` (публичный `wss://rtc.<домен>`), `FG_LIVEKIT_API_KEY`,
`FG_LIVEKIT_API_SECRET`. Не заданы → звонки выключены (`/api/info` → `"calls":false`).

```jsonc
// Call (state: ringing|active|ended|missed|declined)
{"id":7,"chat_id":3,"initiator_id":1,"video":true,"state":"active",
 "participant_ids":[1,2],"created_at":1731400000000,"answered_at":1731400005000,"ended_at":null}
// CallJoin
{"call":Call,"livekit_url":"wss://rtc.example.ru","token":"<jwt>"}
```

* `GET /api/info` дополнительно → `"calls":true|false`.
* `POST /api/chats/{id}/call` `{video}` → `CallJoin`. Если в чате уже идёт звонок — возвращает его
  (присоединение). Остальным участникам — событие `call.ring` (Call).
* `POST /api/calls/{id}/join` → `CallJoin` (принять). Первый принявший переводит `ringing → active`.
* `POST /api/calls/{id}/decline` → 204. В личном чате завершает звонок со статусом `declined`.
* `POST /api/calls/{id}/leave` → 204. Звонок завершается, когда в нём не осталось участников
  (в личном — когда вышел любой из двух).
* `GET /api/calls?limit=50` → `[Call]` — история звонков пользователя, новые сверху.
* Без ответа 45 с → `missed`. Активный звонок без участников (по вебхукам LiveKit) → `ended`.
* `POST /api/livekit/webhook` — вебхуки LiveKit (`participant_joined/left`, `room_finished`),
  подпись проверяется ключом API. Комната LiveKit = `call-<id>`, identity = `<user_id>`,
  name = display_name, токен на 6 ч, права только на эту комнату.

События WebSocket: `call.ring` (Call), `call.updated` (Call — принят/участники изменились),
`call.ended` (Call). По завершении в чат пишется сообщение `kind:"call"` с полем
`"call":{"id","video","state","duration_ms"}` («Видеозвонок · 2:14», «Пропущенный звонок»).

Звонок на закрытый iPhone (этап 3): при `call.ring` сервер шлёт участникам VoIP-push
(PushKit, тема `<bundle>.voip`, `apns-push-type: voip`, `apns-expiration: 0`) с
`{uuid, call_id, chat_id, caller_name, title, video}`. `uuid` — детерминированный UUID
звонка `00000000-0000-4000-8000-<id hex>`, одинаково считается на сервере и в клиенте.
iOS обязана сразу показать такой push в CallKit, иначе перестаёт будить приложение;
если UI-движок Flutter ещё не запущен, `AppDelegate.swift` поднимает минимальный движок
(`callkitHostMain`, пустая Dart-функция) только чтобы зарегистрировать плагин CallKit.
Клиент: ответ в CallKit сразу вызывает `join` и подключает LiveKit вне экрана
(`CallConnection`), потому что на заблокированном телефоне кадры не рисуются; экран
звонка подхватывает готовое соединение. Пока звонит системный экран, внутреннее
окно входящего звонка не показывается. Звонок, закончившийся без ответа, приходит
обычным push «Пропущенный звонок». Android (FCM + ConnectionService) — позже.

## Push-уведомления (этап 3)

* Сервер шлёт в APNs напрямую (HTTP/2, токен-авторизация ключом `.p8`, ES256 JWT,
  переподписывается раз в 40 мин), без Firebase. Настройка: `FG_APNS_KEY_FILE`,
  `FG_APNS_KEY_ID`, `FG_APNS_TEAM_ID`, `FG_APNS_TOPIC` (bundle ID). Без ключа push выключен.
* Таблица `push_devices(token, user_id, session_hash, platform, sandbox)`: токен
  привязан к сессии (`ON DELETE CASCADE`), выход из аккаунта прекращает push на этот телефон.
  Токены, на которые APNs отвечает 410/`BadDeviceToken`/`Unregistered`, удаляются.
* `sandbox`: сборки с development-подписью получают токены песочницы APNs; клиент
  определяет это по `aps-environment` в embedded.mobileprovision.
* Новое сообщение → push всем участникам чата, кроме отправителя (в фоне, не задерживая
  ответ). Личный чат: заголовок — имя отправителя; группа: название группы и «Имя: текст».
  Вложения: «📷 Фото», «🎬 Видео», «🎤 Голосовое сообщение», «📎 имя файла».
  `badge` — непрочитанные во всех чатах, `thread-id` — `chat-<id>`, `chat_id` — какой чат открыть.
* Клиент iOS: нативный мост в `AppDelegate.swift` (канал `familygram/push`), Dart —
  `lib/data/push.dart`. В открытом приложении уведомления не показываются.
