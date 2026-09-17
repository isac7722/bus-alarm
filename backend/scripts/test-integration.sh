#!/usr/bin/env bash
# Each run owns a private network and containers, never application data.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--checks" ]; }; then
  echo "Usage: $0 [--checks]" >&2
  exit 2
fi
repo_root="$(cd .. && pwd)"
run_id="buswidget-go-test-$(date +%s)-$$"
postgres_name="${run_id}-postgres"
redis_name="${run_id}-redis"
runner_name="${run_id}-runner"
cleanup() {
  docker rm -fv "$runner_name" "$postgres_name" "$redis_name" >/dev/null 2>&1 || true
  docker network rm "$run_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker network create "$run_id" >/dev/null
docker run -d --name "$postgres_name" --network "$run_id" --network-alias postgres \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=buswidget \
  postgres:17-alpine >/dev/null
docker run -d --name "$redis_name" --network "$run_id" --network-alias redis \
  redis:7.4-alpine >/dev/null
for attempt in {1..30}; do
  if docker exec "$postgres_name" pg_isready -U postgres -d buswidget >/dev/null 2>&1 && \
     docker exec "$redis_name" redis-cli ping >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 30 ]; then
    echo "Test services did not become ready" >&2
    exit 1
  fi
  sleep 1
done
echo "Docker의 Go 1.26.1 환경에서 백엔드 테스트를 실행합니다."
# Bookworm includes the C compiler required by Go's race detector. Keep source
# read-only, reuse compilation/module caches, and do not mount the Docker socket.
docker run --rm --name "$runner_name" --network "$run_id" \
  --mount "type=bind,src=$repo_root,dst=/workspace,readonly" \
  --mount type=volume,src=buswidget-test-gomod,dst=/go/pkg/mod \
  --mount type=volume,src=buswidget-test-gobuild,dst=/root/.cache/go-build \
  --workdir /workspace/backend \
  -e TEST_DATABASE_URL=postgresql://postgres:test@postgres:5432/buswidget \
  -e TEST_REDIS_URL=redis://redis:6379/0 \
  -e CGO_ENABLED=1 -e GOFLAGS=-mod=readonly \
  golang:1.26.1-bookworm bash -euo pipefail -c '
    if [ "${1:-}" = "--checks" ]; then
      unformatted="$(gofmt -l cmd internal app/content/content.go)"
      if [ -n "$unformatted" ]; then
        echo "gofmt 검사가 실패했습니다:" >&2
        echo "$unformatted" >&2
        exit 1
      fi
      go vet ./...
    fi
    go test -race -count=1 -cover ./...
  ' -- "$@"
