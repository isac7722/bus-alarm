# BusWidget

서울 버스 정류소를 검색하고 선택한 노선의 최대 2대 도착 정보를 iOS 홈 화면 위젯에 표시하는 MVP입니다. 서울시 버스 API 키는 백엔드에만 저장하며, iOS 앱과 위젯은 정규화된 FastAPI API만 호출합니다.

## 구성

- `backend/`: FastAPI, PostgreSQL, Redis, Alembic, 서울시 XML API 어댑터
- `ios/`: SwiftUI 앱, WidgetKit extension, 공유 App Group 저장소
- `seoul_bus_statiosn.xlsx`: 정류소/노선 카탈로그 원본
- `docker-compose.yml`: PostgreSQL 17, Redis 7.4, migration, catalog import, API

카탈로그 import는 서울 NODE_ID만 선별하며 현재 원본 기준 정류소 11,161개, 노선 718개, 노선-정류소 38,526건을 적재합니다. `ARS_ID`는 선행 0을 포함한 5자리 문자열로 보존합니다.

## 빠른 시작

요구 사항은 Docker Desktop, Xcode 26+, Homebrew, XcodeGen입니다.

```bash
brew install xcodegen
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
cp backend/.env.example backend/.env
```

`backend/.env`의 `SEOUL_BUS_API_KEY`에 [공공데이터포털 서울특별시 버스도착정보조회 서비스](https://www.data.go.kr/data/15000314/openapi.do)에서 발급받은 **디코딩된 일반 인증키**를 넣습니다. 이미 `%2B`, `%2F`처럼 URL 인코딩된 키라면 먼저 디코딩해야 HTTP 클라이언트의 이중 인코딩을 피할 수 있습니다.

외부 API 인증을 기다리는 동안에는 `backend/.env`에 `MOCK_ARRIVALS=true`를 설정할 수 있습니다. 이 모드는 정류소 검색과 노선 목록에는 실제 로컬 카탈로그를 사용하고, 도착 정보만 노선별 2대의 가짜 데이터로 생성합니다. 실제 연동으로 돌아갈 때는 값을 `false`로 바꾸고 backend 컨테이너를 다시 생성합니다.

```bash
make dev
```

`make dev`는 Docker 서버를 백그라운드로 실행하고 `/health` 응답을 확인한 다음 Xcode 프로젝트를 생성해 엽니다. 사용 가능한 명령은 `make help`로 확인합니다.

```text
make dev       서버 실행 후 Xcode 열기
make server    서버만 실행
make xcode     Xcode 프로젝트 생성 후 열기
make stop      서버 종료
make restart   backend 재빌드 및 재시작
make logs      backend 로그 확인
make status    컨테이너 상태 확인
make test      백엔드 및 iOS 테스트
make help      전체 명령 도움말
```

첫 실행에서 Alembic migration과 전체 엑셀 import가 자동으로 완료된 뒤 API가 시작됩니다. 호스트 포트는 API 8000, PostgreSQL 5433, Redis 6379입니다.

## iOS 실행

서버가 이미 실행 중이면 프로젝트 루트에서 `make xcode`만 실행합니다. 서버까지 함께 시작하려면 `make dev`를 사용합니다.

Xcode에서 다음을 설정합니다.

1. 앱과 위젯 target의 Signing Team을 선택합니다.
2. 두 target에 App Groups capability를 추가하고 `group.com.pangjoong.buswidget`을 활성화합니다.
3. Debug 시뮬레이터는 기본 `http://127.0.0.1:8000`을 사용합니다.
4. 실기기는 `Config/Local.xcconfig.example`을 `Config/Local.xcconfig`로 복사하고 API URL을 Mac의 LAN 주소(예: `http://192.168.0.10:8000`)로 바꿉니다. iPhone과 Mac은 같은 네트워크에 있어야 합니다.

앱 번들 ID는 `com.pangjoong.BusWidget`, 위젯은 `com.pangjoong.BusWidget.BusWidgetExtension`입니다. iOS는 임베드된 extension ID가 부모 앱 ID로 시작하도록 강제하므로 이 접두어 관계를 유지해야 합니다. 실제 배포 전에는 `Config/Release.xcconfig`의 placeholder를 HTTPS 백엔드 URL로 교체합니다.

앱에서 정류소를 검색하고 노선을 최대 4개 선택해 저장한 뒤 `버스 도착` 위젯을 추가합니다. 홈 화면 소형은 최대 2개, 중형은 최대 4개 노선을 표시합니다. 잠금 화면에서는 직사각형이 앞의 2개 노선을, 원형과 인라인이 첫 번째 노선을 표시하며 도착 시간은 `2분`, `곧`, `도착`처럼 간결하게 표시됩니다.

잠금 화면 위젯은 잠금 화면을 길게 누른 뒤 `사용자화` → `잠금 화면` → 시계 아래 위젯 영역 → `버스 도착` 순서로 추가합니다. 시계 위 영역에는 인라인, 시계 아래 영역에는 원형 또는 직사각형 위젯을 배치할 수 있습니다.

## API

```text
GET /health
GET /api/v1/stations/search?q=강남
GET /api/v1/stations/{station_id}
GET /api/v1/stations/{station_id}/arrivals?route_ids=100100341,100100360
```

- 도착 조회는 정류소당 서울시 `getStationByUid`를 한 번 호출하고 Redis에 기본 30초간 캐시한 뒤 노선을 필터링합니다.
- `route_ids`는 쉼표 구분이며 중복 제거 후 최대 4개입니다.
- 각 노선은 최대 2개의 예측을 `arrival_at`, `remaining_seconds`, `remaining_stops`, `vehicle_status`로 반환합니다.
- API v1은 Redis 기반 IP 고정 윈도우 rate limit(기본 60회/60초)을 적용합니다.
- Redis와 PostgreSQL은 필수 의존성이며 시작 시 연결되지 않으면 API도 시작하지 않습니다.

오류는 모든 endpoint에서 같은 형식입니다.

```json
{
  "error": {
    "code": "STATION_NOT_FOUND",
    "message": "정류소를 찾을 수 없습니다."
  }
}
```

Swagger UI는 로컬 실행 후 [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)에서 확인할 수 있습니다.

## 검증

백엔드:

```bash
cd backend
uv sync
uv run ruff check app tests
uv run mypy app
uv run pytest --cov=app
```

iOS:

```bash
cd ios
xcodegen generate
xcodebuild -project BusWidget.xcodeproj -scheme BusWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

실기기에서는 App Group 공유, 앱 저장 직후 위젯 reload, 소형/중형 레이아웃, 라이트/다크 모드, 큰 글자, 네트워크 단절 시 마지막 성공 데이터와 stale 표시를 별도로 확인해야 합니다. WidgetKit 갱신 시각은 시스템 budget에 따라 달라지므로 디버거 결과만으로 운영 갱신 주기를 보장할 수 없습니다.
