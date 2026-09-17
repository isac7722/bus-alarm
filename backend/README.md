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

## 전국 CSV로 서울·경기도 경유 정류장 보강

프로젝트 루트의 Make 명령으로 실행할 수 있습니다.

| 명령 | 동작 |
| --- | --- |
| `make setup` | `uv sync --locked`로 도구 설치 |
| `make stations-check` | DB 연결 없이 CSV 검증 |
| `make stations-preview` | 추가·수정 예정 건수 확인 |
| `make stations-update` | 실제 추가·수정 적용 |
| `make test-stations` | lint·포맷·단위/통합 테스트 |

기본 대상은 실행 중인 Compose의 `postgres` 서비스입니다.
다른 서버의 DB는 `make stations-preview ENV_FILE=backend/.env`로 확인하고
`make stations-update ENV_FILE=backend/.env`로 적용합니다. `ENV_FILE`을 명시하면
해당 파일에서 읽은 `DATABASE_URL`로 직접 연결합니다. 기존 프로세스 환경변수가 파일보다 우선합니다.
현재 검증한 uv 0.11.1에서는 환경 파일 경로에 공백이 있으면 읽지 못하므로 `ENV_FILE`에는 공백 없는 경로를 사용합니다.
다른 환경변수 이름은 `DB_ENV=이름`, 다른 CSV는 `CSV='/경로/파일.csv'`,
다른 로컬 PostgreSQL 컨테이너는 `CONTAINER=이름`으로 지정합니다.
직접 연결과 `CONTAINER`는 동시에 사용할 수 없습니다.

저장소 루트에서 `uv sync`를 실행하면 `.python-version`의 Python 3.12와
`uv.lock`에 고정된 패키지로 실행 환경을 구성합니다. Python 스크립트용 설정이며 Go 백엔드 실행 방식은 동일합니다.
`psycopg[binary]`를 포함하므로 PostgreSQL 직접 연결 시 시스템 `psql`·libpq·Docker 설치가 필요 없습니다.
기본 입력은 저장소 루트의 `national_bus_station_data_20251031.csv`입니다.
다른 파일은 `--csv '/경로/파일.csv'`로 지정합니다. CP949와 UTF-8을 지원합니다.
다른 서버에는 `pyproject.toml`, `uv.lock`, `.python-version`, 스크립트와 CSV를 함께 배포하세요.

프로젝트 루트에서 초기 설정과 CSV 검증을 실행합니다.

```bash
uv sync

# DB 연결 없이 CSV 검증
uv run python backend/scripts/update_seoul_stations.py --validate-only
```

기존 Compose 서버에서는 기본 실행으로 `postgres` 서비스의 `buswidget` DB에 접속합니다.
이 모드는 환경변수 `DATABASE_URL`을 사용하지 않습니다.

```bash
# 기존 로컬 DB를 시작한 뒤 반영 예정 건수 확인 (기본값: dry run)
docker compose up -d postgres
uv run python backend/scripts/update_seoul_stations.py

# 정류장 추가·수정 적용
uv run python backend/scripts/update_seoul_stations.py --apply
```

다른 서버의 PostgreSQL에 직접 연결하려면 해당 서버에서 접근 가능한 `DATABASE_URL`을
환경변수로 설정하거나 `backend/.env`에 설정하고 다음처럼 실행합니다.
`.env`는 자동으로 읽지 않으며 `uv run --env-file`로 명시합니다.
`--database-url-env`는 URL 자체가 아닌 **환경변수 이름**을 받습니다.

```bash
# backend/.env의 DATABASE_URL로 미리보기
uv run --env-file backend/.env python backend/scripts/update_seoul_stations.py \
  --database-url-env DATABASE_URL

# 같은 DB에 적용
uv run --env-file backend/.env python backend/scripts/update_seoul_stations.py \
  --database-url-env DATABASE_URL --apply
```

이미 환경변수가 설정되어 있으면 `--env-file backend/.env`를 생략합니다.
지정한 환경변수가 없거나 비어 있으면 오류로 종료하며 Docker 연결로 대체하지 않습니다.
기존 `postgresql+asyncpg://`와 `postgresql://`, `postgres://` 주소를 지원합니다.
TLS가 필요한 서버에서는 URL에 `sslmode=require` 또는 해당 서버의 인증서 검증 설정을 지정합니다.
호스트에서 Compose DB에 직접 연결할 때는 `127.0.0.1:5433`을 사용합니다.
컨테이너 내부용 호스트 이름 `postgres:5432`는 호스트나 다른 서버에서 그대로 사용할 수 없습니다.

서버에서 잠금 파일을 변경하지 않고 설치하려면 다음 명령을 사용할 수 있습니다.

```bash
uv sync --locked --no-dev
```

테이블이 없는 새 DB에서는 기존 `migrate`, `import-stations`로 서울 엑셀 카탈로그를 먼저 구성합니다.
이 스크립트는 기존 DB 보강용이며 노선 데이터를 초기화하지 않습니다.

- `도시코드=11`, `관리도시명=서울BIS`인 자료에서 `SEB1`로 시작하는 서울 노드와 `SEB2`로 시작하는 경기도 경유 노드를 사용합니다. 접두어 뒤 숫자는 9자리여야 합니다.
- 서울BIS의 경기도 경유 정류장도 원본 도시코드가 `11`이므로, 같은 숫자 노드 ID의 경기BIS 행에서 경기도 도시코드(`31`로 시작하는 5자리)를 확인합니다. 매칭이 없거나 지역이 모호하면 제외합니다. 경기BIS 행은 지역 확인용으로만 사용하며, 도착정보 조회에 쓰는 ARS 번호는 서울BIS 값을 유지합니다. 경기도 전체 정류장을 가져오는 기능은 아닙니다.
- `SEB` 접두어를 제거해 기존 `node_id`와 대조하고, ARS 번호는 앞자리 0을 보완해 5자리로 저장합니다. 유효한 ARS 번호가 없는 행은 제외합니다.
- 동일한 ARS·노드 ID의 이름·좌표를 수정하고 신규 정류장을 추가합니다. ARS 번호와 노드 ID의 매핑이 충돌하면 해당 행은 건너뛰고 건수와 최대 20개 예시를 출력합니다.
- CSV 내부에서 ARS 또는 노드 ID가 중복되는 후보는 모두 제외합니다. 출력의 `source.excluded_ambiguous_id_rows`와 `ambiguous_id_sample`로 확인할 수 있습니다. 기존 DB에 있는 해당 정류장은 그대로 유지합니다.
- 기존 정류장 삭제, ID 변경, `routes`·`route_stops` 변경은 하지 않습니다. CSV에서 빠진 기존 정류장은 유지합니다. 전체 작업은 한 트랜잭션으로 적용하며 오류가 발생하면 롤백합니다.
- 기본 실행은 DB의 변경 예정 건수만 출력하고 롤백합니다. `--apply`로 적용 후 재실행하면 동일 데이터는 수정하지 않습니다.
- CSV는 2025-10-31 시점의 위치정보입니다. 이후 변경된 이름·좌표를 되돌릴 수 있으므로 더 최신 자료가 반영된 DB에는 이 스냅샷을 사용하지 마세요. 기존 테이블에는 수집일이 없어 신구 비교를 자동으로 할 수 없습니다.
- **새로 추가되는 정류장은 검색되지만, CSV에 노선 정보가 없어 노선 선택·알림 설정이 가능해지는 것은 아닙니다.** 노선 연결은 별도 데이터로 보강해야 합니다.
- 기존 `import-stations` 명령은 엑셀 기준으로 카탈로그 전체를 교체합니다. `make server` 등으로 다시 실행되면 CSV 보강 내용이 덮어써질 수 있으므로 엑셀 import 이후 이 스크립트를 다시 적용해야 합니다.
- 기존 도착정보 캐시는 별도로 지우지 않으며 설정된 TTL에 따라 만료됩니다.

스크립트 단위 테스트:

```bash
uv run python -m unittest discover -s backend/scripts/tests -v
uv run ruff check backend/scripts
uv run ruff format --check backend/scripts
```

통합 테스트는 `TEST_STATION_CONTAINER`에 `bus-alarm-station-test-`로 시작하는
**폐기 가능한 전용 PostgreSQL 컨테이너** 이름을 지정하면 실행됩니다.
해당 DB의 정류장·노선 테이블을 테스트마다 재생성하므로 개발 DB는 지정하지 않습니다.
컨테이너에는 사용자·DB 이름이 모두 `buswidget`, 비밀번호가 `buswidget`이어야 하며,
포트는 `-p 127.0.0.1::5432`로 게시해야 합니다. Docker와 직접 연결 양쪽을 검증합니다.

## 백엔드 전체 검증

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
