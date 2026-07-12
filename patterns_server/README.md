# Telegram pattern host

This container publishes `../config/telegram_patterns.yaml` through Traefik at:

https://telegram-patterns.sander.dnsrouter.nl/telegram_patterns.yaml

The app keeps the embedded pattern document as its fallback. When a Telegram
message arrives it sends the cached ETag and only replaces its local YAML copy
when the server returns a changed and validated document.

To publish on the Pi, copy this directory together with `../config` to
`/home/pi/apps/telegram-patterns`, then run:

```sh
docker compose -f patterns_server/docker-compose.yml up -d --build
```
