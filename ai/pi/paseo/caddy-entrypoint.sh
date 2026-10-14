#!/usr/bin/env bash
# Adapt the systemd LoadCredentialEncrypted secret to the environment Caddy's
# GoDaddy DNS-01 module expects, without ever placing the token in argv or
# printing it to the service journal.

set -euo pipefail

readonly credential=${CREDENTIALS_DIRECTORY:?}/godaddy-api-token
[[ -f "$credential" ]] || {
  printf 'error: GoDaddy credential is unavailable\n' >&2
  exit 1
}
GODADDY_API_TOKEN=$(<"$credential")
[[ "$GODADDY_API_TOKEN" == *:* && "$GODADDY_API_TOKEN" != *$'\n'* ]] || {
  printf 'error: GoDaddy credential format is invalid\n' >&2
  exit 1
}
export GODADDY_API_TOKEN
exec /usr/local/lib/pi-webui/caddy run \
  --config /etc/pi-webui-caddy/Caddyfile \
  --adapter caddyfile
