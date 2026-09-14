#!/usr/bin/env bash
# Each run owns its containers and uses random host ports, never application data.
set -euo pipefail
cd "$(dirname "$0")/.."
run_id="buswidget-go-test-$$"
postgres_name="${run_id}-postgres"
redis_name="${run_id}-redis"
cleanup() {
  docker rm -f "$postgres_name" "$redis_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$postgres_name" \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=buswidget \
  -p 127.0.0.1::5432 postgres:17-alpine >/dev/null
docker run -d --name "$redis_name" -p 127.0.0.1::6379 redis:7.4-alpine >/dev/null
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
postgres_address="$(docker port "$postgres_name" 5432/tcp)"
redis_address="$(docker port "$redis_name" 6379/tcp)"
TEST_DATABASE_URL="postgresql://postgres:test@${postgres_address}/buswidget" \
TEST_REDIS_URL="redis://${redis_address}/0" \
  go test -race -count=1 -cover ./...
