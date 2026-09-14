FROM golang:1.26.1-bookworm AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY app/content ./app/content
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /buswidget ./cmd/buswidget

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system buswidget \
    && useradd --system --gid buswidget --home-dir /app buswidget
WORKDIR /app
COPY --from=builder /buswidget /usr/local/bin/buswidget
USER buswidget
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD ["buswidget", "healthcheck"]
ENTRYPOINT ["buswidget"]
CMD ["serve"]
