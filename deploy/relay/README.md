# Релей в России перед основным сервером

Если IP основного (зарубежного) сервера блокируют или режут по скорости,
перед ним можно поставить дешёвый российский VPS. Он работает как
**прозрачный TCP-прокси на 443**: принимает TLS-соединение и, не расшифровывая
его, пересылает на основной сервер. Сертификат и все данные остаются только
на основном сервере, а релей ничего не хранит и прочитать трафик не может.

```
клиент ──TLS:443──▶ RU-релей (nginx stream) ──TCP:443──▶ основной сервер (Caddy)
```

## Что понадобится

* VPS в России, минимальный тариф (1 vCPU, 512 МБ). Трафик звонков и файлов
  идёт через него, поэтому лучше брать тариф без жёсткого лимита трафика.
* Основной сервер Familygram, уже работающий по инструкции из корневого README.

## DNS

Клиенты должны приходить на релей, а Let's Encrypt должен выдать сертификат
основному серверу. Проще всего так:

1. Домен приложения (`family.example.com`) и поддомены звонков
   `rtc.family.example.com` и `turn.family.example.com` направьте **на IP релея**
   (три A-записи).
2. Порт 80 релея тоже пробросьте на основной сервер (см. конфиг ниже), тогда
   HTTP-проверка Let's Encrypt пройдёт через релей и Caddy получит сертификат
   как обычно.

Если основной сервер нужен и напрямую (например, как запасной адрес), заведите
второй домен (`direct.example.com`) с A-записью на основной сервер и добавьте
его в Caddyfile рядом с первым.

## nginx на релее

```bash
apt-get update && apt-get install -y nginx libnginx-mod-stream
```

Добавьте в конец `/etc/nginx/nginx.conf` (вне блока `http { }`), заменив
`203.0.113.10` на IP основного сервера:

```nginx
stream {
    # Familygram relay: transparent TCP passthrough, TLS is NOT terminated here.
    # All three names go to the same Caddy: it routes app / rtc. / turn. by SNI.
    map $ssl_preread_server_name $fg_backend {
        family.example.com       203.0.113.10:443;
        rtc.family.example.com   203.0.113.10:443;
        turn.family.example.com  203.0.113.10:443;
        default                  203.0.113.10:443;
    }

    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;               # read SNI without decrypting
        proxy_pass $fg_backend;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;             # long-lived WebSocket connections
        tcp_nodelay on;
    }

    # HTTP (Let's Encrypt HTTP-01 + redirect to HTTPS) is passed through too.
    server {
        listen 80;
        listen [::]:80;
        proxy_pass 203.0.113.10:80;
    }

    # Optional: fast path for call media. Not needed for calls to work —
    # without it they go through TURN/TLS on 443 (above).
    server {
        listen 7881;
        proxy_pass 203.0.113.10:7881;
    }
    server {
        listen 7882 udp;
        proxy_pass 203.0.113.10:7882;
        proxy_responses 0;   # many datagrams in both directions
        proxy_timeout 1h;
    }
}
```

> **Звонки через релей.** Достаточно одного порта 443: если 7881/7882 закрыты
> или режутся, LiveKit сам переходит на TURN поверх TLS (`turn.<домен>:443`),
> а он проходит через тот же `ssl_preread`. Прямые UDP/TCP-порты дают лучшее
> качество, но при блокировках они первыми перестают работать.
>
> Учтите: LiveKit сообщает клиентам IP основного сервера для портов 7881/7882
> (`use_external_ip`). Если основной IP заблокирован, эти пути не сработают
> даже через релей — звонки всё равно пойдут через `turn.<домен>:443`, т.е.
> через релей. Это нормальный и ожидаемый режим.

Удалите сайт по умолчанию, который занимает порт 80, и перезапустите nginx:

```bash
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

### Вариант с HAProxy

```haproxy
frontend fg_tls
    bind :443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend fg_main

backend fg_main
    mode tcp
    timeout server 1h
    server main 203.0.113.10:443
```

## Проверка

```bash
curl -I https://family.example.com          # должен ответить Caddy основного сервера
curl -I https://rtc.family.example.com      # LiveKit (ответ 200/404 — главное, что TLS работает)
openssl s_client -connect turn.family.example.com:443 -servername turn.family.example.com </dev/null | grep subject
openssl s_client -connect family.example.com:443 -servername family.example.com </dev/null | grep subject
```

## Реальный IP клиентов

Основной сервер увидит IP релея вместо IP клиента. Для семьи это не мешает.
Единственное последствие: лимит «запросов SMS с одного IP» считается общим
для всех, кто ходит через релей. Если это мешает, включите PROXY protocol
(`proxy_protocol on;` в nginx и `proxy_protocol` в Caddy) — это отдельная
настройка, по умолчанию выключена.

## Честно об ограничениях

* **Гарантированно неблокируемого решения нет.** Релей защищает от блокировки
  IP основного сервера и от замедления зарубежного трафика. Сам трафик
  выглядит как обычный HTTPS-сайт.
* **Белые списки.** Когда на мобильном интернете включают белые списки,
  работают только разрешённые ресурсы. Российский IP релея повышает шансы, но
  ничего не гарантирует: если IP или домен не попал в список, соединения не будет.
* **Релей можно заблокировать так же, как любой сайт.** Держите наготове
  запасной домен и/или второй релей у другого провайдера. В клиенте
  планируется список зеркал (этап 3), который будет перебирать адреса
  автоматически.
* **Хостинг в России** подпадает под российское регулирование. Релей видит
  только зашифрованный трафик и метаданные (кто и когда подключался), но не
  содержимое.
* **Звонки** через релей идут по TURN/TLS на 443 — внешне это такой же HTTPS,
  как и остальной трафик. Качество чуть хуже, чем по прямому UDP, из-за лишнего
  плеча до основного сервера.
