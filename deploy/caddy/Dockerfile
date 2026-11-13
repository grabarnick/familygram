# Caddy with the layer4 module (github.com/mholt/caddy-l4).
# Needed to share TCP 443 between the HTTPS site and LiveKit's TURN/TLS:
# connections for turn.<domain> are routed by SNI before the HTTP server sees them.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/mholt/caddy-l4

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
