#!/usr/bin/env bash
# Familygram installer for a fresh Ubuntu/Debian VPS. Non-interactive.
#
#   FG_DOMAIN=family.example.com FG_ADMIN_PHONE=+79990000000 ./install.sh
#   ./install.sh family.example.com +79990000000
#
# Prerequisites: DNS A records for <domain>, rtc.<domain> and turn.<domain>
# point to this server; ports 80/tcp, 443/tcp, 7881/tcp, 7882/udp are open.
set -euo pipefail

cd "$(dirname "$0")"

FG_DOMAIN="${1:-${FG_DOMAIN:-}}"
FG_ADMIN_PHONE="${2:-${FG_ADMIN_PHONE:-}}"

if [[ -z "$FG_DOMAIN" || -z "$FG_ADMIN_PHONE" ]]; then
  echo "usage: $0 <domain> <admin-phone>   (or set FG_DOMAIN and FG_ADMIN_PHONE)" >&2
  echo "example: $0 family.example.com +79990000000" >&2
  exit 1
fi
if [[ ! "$FG_ADMIN_PHONE" =~ ^\+[0-9]{10,15}$ ]]; then
  echo "admin phone must be in international format, e.g. +79990000000" >&2
  exit 1
fi

# --- Docker -----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  if [[ $EUID -ne 0 ]]; then
    echo "run as root (or install Docker first)" >&2
    exit 1
  fi
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is missing (apt-get install docker-compose-plugin)" >&2
  exit 1
fi

# --- .env -------------------------------------------------------------------
if [[ -f .env ]]; then
  echo "==> Keeping existing .env (updating FG_DOMAIN and FG_ADMIN_PHONE)"
  sed -i.bak \
    -e "s|^FG_DOMAIN=.*|FG_DOMAIN=${FG_DOMAIN}|" \
    -e "s|^FG_ADMIN_PHONE=.*|FG_ADMIN_PHONE=${FG_ADMIN_PHONE}|" .env
  rm -f .env.bak
else
  echo "==> Writing .env"
  sed \
    -e "s|^FG_DOMAIN=.*|FG_DOMAIN=${FG_DOMAIN}|" \
    -e "s|^FG_ADMIN_PHONE=.*|FG_ADMIN_PHONE=${FG_ADMIN_PHONE}|" \
    .env.example > .env
fi
chmod 600 .env

# --- LiveKit keys (calls) ---------------------------------------------------
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
set_env() {
  if grep -q "^$1=" .env; then
    sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
  else
    echo "$1=$2" >> .env
  fi
}
if ! grep -q '^FG_LIVEKIT_API_KEY=.\+' .env; then
  echo "==> Generating LiveKit API key/secret"
  set_env FG_LIVEKIT_API_KEY "API$(rand_hex 6)"
  set_env FG_LIVEKIT_API_SECRET "$(rand_hex 32)"
fi

# --- Start ------------------------------------------------------------------
echo "==> Building and starting (first build takes several minutes)"
docker compose up -d --build

cat <<EOF

DNS records required (A, all to this server's IP):
  ${FG_DOMAIN}
  rtc.${FG_DOMAIN}     (call signaling)
  turn.${FG_DOMAIN}    (call media over TLS on 443)

Firewall: open 80/tcp, 443/tcp, 7881/tcp, 7882/udp.
(7881/7882 are a fast path for calls; if they are blocked, calls still
work through TURN over TLS on 443.)

Familygram is starting at https://${FG_DOMAIN}
(the TLS certificate is issued automatically within a minute).

Sign in: open https://${FG_DOMAIN} or the mobile app, enter server
${FG_DOMAIN} and the admin phone ${FG_ADMIN_PHONE}.

SMS provider is "log" by default: the login code is written to the log:
  docker compose logs -f familygram
To send real SMS set FG_SMS_PROVIDER (smsru | smsc | twilio) and its keys
in $(pwd)/.env, then: docker compose up -d

Add family members (in the app as admin, or here):
  docker compose exec familygram familygram add-phone +79991234567 "Мама"
EOF
