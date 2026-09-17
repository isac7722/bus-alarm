# BusWidget backend

Go 1.26.1 기반 BusWidget API입니다. 전체 앱 실행은 상위 [README](../README.md)를 참고하세요.

실시간 현황의 등록·종료 API와 APNs 갱신 워커도 제공합니다. [APNs 키·Docker 설정과 API 계약](../docs/live-activities.md)을 참고하세요. APNs 설정이 없으면 기존 조회 API만 동작합니다.

## 실행

기존 `make server`와 `docker compose up --build -d`는 PostgreSQL → 마이그레이션 → 정류소 import → API 순서로 실행합니다. API는 8000 포트를 사용합니다.

이미 실행 중인 서버의 백엔드만 반영할 때는 다음을 **실제 서빙하는 서버의 저장소 디렉터리에서** 사용합니다. 서버의 `backend/.env`에 필요한 API 키를 먼저 설정하세요. 개발 PC의 `.env`와 DB 데이터는 Git으로 전달되지 않습니다. 경기 API 연동은 노선을 DB에 적재하는 방식이 아니므로 정류소 CSV 재반영이나 DB 마이그레이션이 필요하지 않습니다.

```bash
make test-backend       # Docker만 필요, Go 검사와 임시 DB·Redis 테스트
make restart APNS=1    # APNs 사용 서버: backend만 재빌드하고 /health 확인
make status
make logs
```

APNs를 사용하지 않으면 `make restart`로 실행합니다. `restart`는 `--no-deps`를 사용하므로 PostgreSQL·Redis가 이미 실행 중이어야 하며, 정류소 import와 마이그레이션은 재실행하지 않습니다. 백엔드 반영 자체에는 Docker만 필요하고 호스트 Go는 필요하지 않습니다. `make test`는 iOS 테스트도 포함하므로 우분투에서는 `make test-backend`를 사용합니다.

시작 직후 종료되면 `docker compose logs --tail=50 backend`를 확인합니다. `command_failed`의 `message`에는 잘못된 설정 이름, DB·Redis 연결 실패, APNs 키 파일 연결·권한 문제처럼 인증정보를 포함하지 않는 원인만 표시합니다. 드라이버·네트워크의 원문 오류와 설정 값은 출력하지 않습니다. APNs 설정이 있는 서버는 재시작 시에도 `APNS=1` 또는 `-f docker-compose.apns.yml`을 반드시 유지하세요.

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
- Redis의 `station:{station_id}:arrivals:{live|mock}`, `rate:{IP}` 키, JSON 값 및 TTL을 유지합니다. 경기 연동은 기존 서울 캐시와 섞이지 않도록 `live-gbis-v1` 네임스페이스를 사용합니다.
- 기본 `STATION_CATALOG_PATH`는 `../seoul_bus_statiosn.xlsx`입니다. 전체 검증 후 한 트랜잭션으로 카탈로그를 교체하며 실패 시 기존 데이터를 보존합니다.
- `app/content/privacy.json`은 iOS가 함께 사용하는 원본입니다. Go 실행 파일에 임베드되므로 수정 후 재빌드해야 합니다. `/privacy`는 DB·캐시 조회 없이 응답합니다.
- `/docs`, `/redoc`, `/openapi.json`은 제공하지 않습니다.

## 정류장 경유노선 조회

실제 서비스에서는 서울시 정류소정보조회 서비스의 `getRouteByStation`으로 경유노선을 조회합니다. 정류장 상세, 도착정보의 노선 검증, 실시간 현황 등록·갱신이 같은 목록을 사용합니다. 도착 예측이 없는 노선도 목록에 표시하며 서울시가 연계 제공하는 경기 노선도 포함합니다. `MOCK_ARRIVALS=true`일 때는 DB의 기존 노선 연결을 사용합니다.

예를 들어 `05267` 테크노마트앞.강변역의 기존 엑셀에는 4개 노선만 있지만, 2026-09-17 실제 API에는 경기상운의 하남시 노선 `9304하남`(`227000040`)을 포함한 18개가 있었습니다. 전국 정류장 CSV에는 노선 정보가 없어 CSV 업데이트만으로는 이 누락을 해결할 수 없습니다.

목록은 Redis의 `station:<정류장 ID>:routes:live`에 도착정보와 별도로 캐시하며 기존 캐시 TTL 설정(기본 30초)을 사용합니다. 외부 API 조회가 실패하면 오류를 반환합니다. 불완전한 엑셀 목록으로 대체하지 않습니다. DB 스키마 변경이나 노선 재수집 없이 백엔드를 재빌드하면 적용됩니다. 경기 API 키가 없을 때 지원 범위는 서울시 API가 제공하는 경유노선입니다.

데이터 출처: [서울특별시 정류소정보조회 서비스](https://www.data.go.kr/data/15000303/openapi.do), [하남시 버스 노선 안내](https://www.hanam.go.kr/www/contents.do?key=5540). 경기도 원본 경유노선은 [GBIS 정류소 경유노선 조회](https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusStationRoute), 도착정보는 [경기도 버스도착정보 조회](https://www.data.go.kr/data/15080346/openapi.do)에서도 제공합니다.

## 경기버스 GBIS 직접 연동

공공데이터포털에서 [경기도 정류소 조회](https://www.data.go.kr/data/15080666/openapi.do)와 [경기도 버스도착정보 조회](https://www.data.go.kr/data/15080346/openapi.do)를 모두 승인받고, `backend/.env`에 디코딩된 일반 인증키를 설정합니다. 같은 계정의 키를 사용하더라도 서비스별 활용 승인이 필요합니다.

```dotenv
GYEONGGI_BUS_API_KEY=승인받은_디코딩_인증키
GYEONGGI_BUS_API_BASE_URL=https://apis.data.go.kr/6410000
```

키를 비워 두면 서울 단독 모드이며, `MOCK_ARRIVALS=true`는 두 외부 API를 모두 사용하지 않습니다. 실제 키는 Git에 넣지 않습니다. `GYEONGGI_BUS_API_BASE_URL`은 서비스별 `/busstationservice/v2` 또는 `/busarrivalservice/v2` 앞의 공통 주소입니다.

| 기능 | GBIS v2 경로 |
| --- | --- |
| 정류소 이름·번호 검색 | `/busstationservice/v2/getBusStationListv2` |
| 정류소 상세 | `/busstationservice/v2/busStationInfov2` |
| 전체 경유노선 | `/busstationservice/v2/getBusStationViaRouteListv2` |
| 도착정보 | `/busarrivalservice/v2/getBusArrivalListv2` |

- 검색은 기존 DB 결과(최대 20개)와 경기 API 결과(최대 20개)를 합칩니다. 같은 노드 ID는 한 번만 표시합니다. 번호와 노드 ID가 모두 기존 DB와 같으면 기존 서울 ID를 유지합니다.
- 서울 ARS와 경기 정류소 번호는 충돌할 수 있으므로 번호만으로 합치지 않습니다. DB에 없는 경기 정류소는 `gg:<9자리 stationId>`로 주소를 지정하며 표시 번호 `ars_id`와 구분합니다. DB 스키마 변경이나 경기 전체 CSV 적재는 필요하지 않습니다. 이름·번호 검색은 GBIS가 제공하는 정류소 범위를 따릅니다.
- 기존 서울 정류소는 DB의 9자리 `node_id`로 경기 API도 조회하고, 서울·경기 경유노선을 노선 ID로 합칩니다. 경기 전용 정류소는 경기 API를 사용합니다. 두 API에 동시에 있는 노선명은 기존 서울 표기를 유지합니다.
- GBIS 경유노선에 포함되는 노선의 도착정보는 GBIS를 사용합니다. 예측이 없다고 다른 공급자의 차량으로 전환하지 않습니다. 도착 예측이 없어도 경유노선 목록에서는 제거하지 않습니다.
- GBIS의 초 단위 예측이 있으면 우선 사용하고, 없으면 분 단위를 초로 변환합니다. 운행 종료·회차 대기는 도착으로 처리하지 않습니다. 같은 노선이 정류소를 여러 번 경유하면 차량을 중복 제거하고 가까운 두 대를 표시합니다. 방향별 노선 선택은 제공하지 않습니다.
- 검색·상세·경유노선 메타데이터와 도착정보를 Redis에 기본 30초간 캐시합니다. 목록·도착정보의 네임스페이스는 `live-gbis-v1`입니다. 인증 실패·외부 API 장애는 오류로 반환하며 부분 목록을 전체 목록처럼 제공하지 않습니다.
- 실시간 현황에도 같은 노선·도착정보를 사용하고 GBIS 차량 ID는 서버 내부에서만 추적합니다. 앱의 API JSON 필드와 저장 형식은 동일합니다. `station_id`는 불투명한 문자열로 취급해야 합니다.

기존 DB·Redis가 실행 중인 서버에서 소스와 `.env`를 반영한 뒤 백엔드만 재빌드합니다. `--no-deps`는 기존 엑셀 import 재실행으로 CSV 보강 내용이 덮이는 것을 방지합니다.

```bash
docker compose up -d --build --no-deps backend
# APNs를 사용 중이라면 기존 추가 파일을 함께 적용:
docker compose -f docker-compose.yml -f docker-compose.apns.yml up -d --build --no-deps backend

curl --fail 'http://localhost:8000/api/v1/stations/search?q=05267'
curl --fail 'http://localhost:8000/api/v1/stations/05267'
curl --fail 'http://localhost:8000/api/v1/stations/05267/arrivals?route_ids=227000040'
```

승인 상태·End Point는 공공데이터포털의 **마이페이지 → 데이터 활용 → Open API → 활용신청 현황 → 해당 서비스 상세**에서 확인합니다. 인증 오류 `30`이면 해당 서비스 승인 상태와 키를 확인합니다. 도착정보 서비스 승인만으로 정류소 검색·경유노선 권한이 생기지는 않습니다.

공식 명세: [정류소 검색](https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusStation), [정류소 상세](https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusStationInfo), [경유노선](https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusStationRoute), [도착정보](https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusArrivalStation).

2026-09-17 승인된 키로 실제 Go 클라이언트·서비스를 검증했습니다. `05267` 검색은 강변역(`104000069`)과 성남 봉화터.군부대앞(`204000294`)을 구분하며, 강변역은 서울·경기 목록을 합쳐 중복 없이 18개 노선을 반환했습니다. 9304번의 두 대 도착 예측, 경기 전용 정류장의 상세·노선·도착정보, 실시간 현황용 스냅샷 조회도 성공했습니다. 운영 서버 배포와 실제 기기 APNs 전달을 검증한 것은 아닙니다.

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
- CSV에는 노선 정보가 없습니다. 실제 모드에서는 추가된 정류장의 경유노선을 서울시 API에서 조회하므로 해당 API가 지원하는 노선을 선택할 수 있습니다. mock 모드의 노선 연결은 별도 DB 데이터가 필요합니다.
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

`test-backend`는 `golang:1.26.1-bookworm` 컨테이너에서 gofmt·go vet 검사 후 `go test -race -count=1 -cover ./...`를 실행합니다. 호스트에 Go·gofmt·C 컴파일러를 설치할 필요가 없습니다. 임시 PostgreSQL 17·Redis 7.4를 별도 Docker 네트워크에서 실행하며 호스트 포트를 열지 않습니다. 테스트 후 컨테이너와 네트워크를 정리하고, 테스트 DB 스키마도 실행마다 분리합니다. 실제 개발·운영 데이터는 사용하지 않습니다.

첫 실행은 Go 이미지와 모듈 다운로드 때문에 시간이 걸릴 수 있습니다. 이후 실행에서는 Docker 볼륨 `buswidget-test-gomod`와 `buswidget-test-gobuild`의 다운로드·빌드 캐시를 재사용합니다. 소스는 컨테이너에 읽기 전용으로 연결합니다. `test-backend-integration`도 같은 Docker 환경을 사용하며, `test-backend-unit`만 호스트 Go·C 컴파일러가 필요합니다.

- 기존 Python 테스트 33개를 기준으로 Go 단위·통합 시나리오를 작성했습니다.
- `internal/server/testdata/python_http.json`, `python_xml.json`은 기존 Python 구현의 고정 입력·출력입니다. 상태 코드, 응답 JSON, 관련 헤더와 개인정보처리방침 HTML을 비교합니다.
- 전체 엑셀 import 결과는 Python이 PostgreSQL에 기록한 세 테이블의 해시와 비교합니다. 기존 Alembic 스키마 재사용, 재실행, 실패 시 롤백과 기존 Redis 캐시·요청 제한 상태도 검사합니다.
- Docker 없이 실행하면 DB·Redis 통합 테스트는 건너뜁니다. `TEST_DATABASE_URL`, `TEST_REDIS_URL`을 지정하면 해당 서비스에서도 통합 테스트를 실행할 수 있습니다.

## 이번 전환에서 보존한 기존 동작

남은 정류장 수를 메시지에서 추출하는 정규식은 공백 제거 처리와 맞지 않는 기존 동작을 유지합니다. `staOrd`·`sectOrd`가 없으면 메시지에 정류장 수가 있어도 null이 될 수 있습니다. 또한 요청 노선 중 upstream 예측이 없는 노선은 요청 순서와 관계없이 응답 뒤쪽에 빈 예측 배열로 추가됩니다. 두 동작 모두 회귀 테스트로 고정했습니다.

### 지도 기반 노선 선택

`/api/v2`는 노선 검색, 방향별 정류장 선택, 경유 순번별 도착정보와 Live Activity를 제공합니다. 기존 v1과 DB 카탈로그는 유지합니다. 기본적으로 새 앱 진입은 비활성화되어 있습니다. 실제 노선 서비스 승인과 `make routes-check` 확인 후 `ROUTE_MAP_ENABLED=true`로 켜세요.

운영 반영 명령과 API 계약은 [지도 선택 API 안내](../docs/design/route-map-api.md)를 참고하세요. 검증은 `make test-backend`, macOS에서는 `make test-ios`와 `make test-route-ui`로 실행합니다.
