# BusWidget backend

Go 1.26.1 기반 BusWidget API입니다. 전체 앱 실행은 상위 [README](../README.md)를 참고하세요.

실시간 현황의 등록·종료 API와 APNs 갱신 워커도 제공합니다. [APNs 키·Docker 설정과 API 계약](../docs/live-activities.md)을 참고하세요. APNs 설정이 없으면 기존 조회 API만 동작합니다.

## 실행

기존 `make server`와 `docker compose up --build -d`는 PostgreSQL → 마이그레이션 → 정류소 import → API 순서로 실행합니다. API는 8000 포트를 사용합니다.

로컬 Go 개발은 PostgreSQL과 Redis를 실행한 뒤 다음 명령을 사용합니다.

```bash
cd backend
cp .env.example .env
go mod download
go run ./cmd/buswidget migrate
go run ./cmd/buswidget import-stations
go run ./cmd/buswidget serve
```

Compose의 PostgreSQL 호스트 포트는 **5433**입니다. 위 로컬 실행에서 Compose DB를 사용하면 `.env`의 `DATABASE_URL` 포트를 5433으로 설정하세요. 컨테이너 간 연결에는 기존대로 5432를 사용합니다.

```bash
go build -o bin/buswidget ./cmd/buswidget
./bin/buswidget healthcheck
```

실행 파일은 `serve`(기본값), `migrate`, `import-stations`, `healthcheck`를 제공합니다. 모든 설정은 기존 이름의 환경변수 또는 작업 디렉터리의 `.env`에서 읽으며 환경변수가 우선합니다. `MOCK_ARRIVALS=true`는 외부 API 호출 없이 노선마다 두 대의 예측을 생성합니다.

## 데이터 호환성

- `postgresql+asyncpg://` 형식의 기존 `DATABASE_URL`과 일반 `postgresql://` 형식을 모두 지원합니다.
- 기존 `alembic_version=0001`과 테이블·인덱스·제약을 그대로 사용합니다. 마이그레이션은 빈 DB를 생성하고, 이미 적용된 DB는 변경하지 않습니다. 알 수 없는 revision은 실패합니다.
- Redis의 `station:{station_id}:arrivals:{live|mock}`, `rate:{IP}` 키, JSON 값 및 TTL을 유지합니다.
- 기본 `STATION_CATALOG_PATH`는 `../seoul_bus_statiosn.xlsx`입니다. 전체 검증 후 한 트랜잭션으로 카탈로그를 교체하며 실패 시 기존 데이터를 보존합니다.
- `app/content/privacy.json`은 iOS가 함께 사용하는 원본입니다. Go 실행 파일에 임베드되므로 수정 후 재빌드해야 합니다. `/privacy`는 DB·캐시 조회 없이 응답합니다.
- `/docs`, `/redoc`, `/openapi.json`은 제공하지 않습니다.

## 검증

프로젝트 루트에서 실행합니다.

```bash
make test-backend
make test-backend-unit
```

`test-backend`는 gofmt·go vet 검사 후 임시 PostgreSQL 17·Redis 7.4 컨테이너에서 `go test -race -count=1 -cover ./...`를 실행하고 컨테이너를 정리합니다. 테스트 DB 스키마도 실행마다 분리합니다. 실제 개발·운영 데이터는 사용하지 않습니다.

- 기존 Python 테스트 33개를 기준으로 Go 단위·통합 시나리오를 작성했습니다.
- `internal/server/testdata/python_http.json`, `python_xml.json`은 기존 Python 구현의 고정 입력·출력입니다. 상태 코드, 응답 JSON, 관련 헤더와 개인정보처리방침 HTML을 비교합니다.
- 전체 엑셀 import 결과는 Python이 PostgreSQL에 기록한 세 테이블의 해시와 비교합니다. 기존 Alembic 스키마 재사용, 재실행, 실패 시 롤백과 기존 Redis 캐시·요청 제한 상태도 검사합니다.
- Docker 없이 실행하면 DB·Redis 통합 테스트는 건너뜁니다. `TEST_DATABASE_URL`, `TEST_REDIS_URL`을 지정하면 해당 서비스에서도 통합 테스트를 실행할 수 있습니다.

## 이번 전환에서 보존한 기존 동작

남은 정류장 수를 메시지에서 추출하는 정규식은 공백 제거 처리와 맞지 않는 기존 동작을 유지합니다. `staOrd`·`sectOrd`가 없으면 메시지에 정류장 수가 있어도 null이 될 수 있습니다. 또한 요청 노선 중 upstream 예측이 없는 노선은 요청 순서와 관계없이 응답 뒤쪽에 빈 예측 배열로 추가됩니다. 두 동작 모두 회귀 테스트로 고정했습니다.
