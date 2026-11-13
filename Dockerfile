# syntax=docker/dockerfile:1
# Familygram: one image = Go server + Flutter web client.

# --- 1. Flutter web client ---------------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock* ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release

# --- 2. Go server ------------------------------------------------------------
FROM golang:1.27-alpine AS server
WORKDIR /src/server
COPY server/go.mod server/go.sum* ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/familygram .

# --- 3. Runtime --------------------------------------------------------------
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -H -u 10001 familygram \
 && mkdir -p /data /app \
 && chown familygram /data
COPY --from=server /out/familygram /usr/local/bin/familygram
COPY --from=web /src/app/build/web /app/web

ENV FG_ADDR=:8080 \
    FG_DATA_DIR=/data \
    FG_WEB_DIR=/app/web \
    FG_SERVER_NAME=Familygram \
    FG_SMS_PROVIDER=log \
    FG_MAX_UPLOAD_MB=200

USER familygram
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/familygram"]
