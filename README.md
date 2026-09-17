# BusWidget

서울·경기 버스 정류장을 지도에서 고르고, 탈 수 있는 버스를 즐겨찾기로 저장하는 iPhone 앱입니다. 선택한 버스의 도착 정보를 앱과 잠금 화면·Dynamic Island의 실시간 현황에서 확인합니다. 버스 API 키는 백엔드에만 저장하며, 앱은 정규화된 Go API를 호출합니다. 경기 정류소 검색과 GBIS 직접 조회는 선택적 경기 API 설정으로 활성화합니다. 현재 배포 대상은 iPhone이며 iPad, Mac Catalyst, Mac·Apple Vision에서의 네이티브 호환 배포는 지원 대상으로 설정하지 않습니다.

## 구성

- `backend/`: Go, PostgreSQL, Redis, SQL 마이그레이션, 서울시·GBIS XML API 어댑터
- `ios/`: SwiftUI 앱, 실시간 현황용 WidgetKit extension, App Group 저장소
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
make restart   기존 DB를 유지하고 backend만 재빌드 및 재시작
make logs      backend 로그 확인
make status    컨테이너 상태 확인
make test      백엔드 및 iOS 테스트
make help      전체 명령 도움말
```

첫 실행에서 Go 마이그레이션과 전체 엑셀 import가 자동으로 완료된 뒤 API가 시작됩니다. 호스트 포트는 API 8000, PostgreSQL 5433, Redis 6379입니다.

## 정류장 데이터 보강

프로젝트 루트에서 실행합니다. uv가 설치되어 있어야 합니다.
기본 입력은 루트의 전국 정류장 CSV이며, 서울과 서울BIS의 경기도 경유 정류장을 보강합니다.

```bash
make setup             # uv sync: Python·패키지 설치
make stations-check    # CSV 검증, DB 접속 없음
make stations-preview  # 추가·수정 예정 건수 확인
make stations-update   # 실제 DB 반영
make test-stations     # 스크립트 검사와 테스트
```

기본 연결은 실행 중인 Compose PostgreSQL입니다. 다른 서버의 DB에 직접 연결하려면
접속 가능한 `DATABASE_URL`이 있는 환경 파일을 지정합니다.

```bash
make stations-preview ENV_FILE=backend/.env
make stations-update ENV_FILE=backend/.env
```

다른 CSV는 `CSV='/경로/정류장.csv'`, 이미 설정한 DB 환경변수는 `DB_ENV=DATABASE_URL`로 지정합니다.
기존 정류장·노선 연결은 보존합니다. 실제 서비스의 경유노선은 서울시 API에서 조회하며, mock 모드만 DB의 노선 연결을 사용합니다.
DB 준비, 제외 기준, 기존 엑셀 import 재실행 시 주의점은 [백엔드 사용 안내](backend/README.md#전국-csv로-서울경기도-경유-정류장-보강)를 참고하세요.

## iOS 실행

서버가 이미 실행 중이면 프로젝트 루트에서 `make xcode`만 실행합니다. 서버까지 함께 시작하려면 `make dev`를 사용합니다.

Xcode에서 다음을 설정합니다.

1. Xcode에 개발자 계정을 연결합니다. 앱과 실시간 현황 확장의 기본 Signing Team은 `ios/project.yml`에 `K5M43RRH97`로 설정되어 프로젝트를 재생성해도 유지됩니다. 다른 Team을 사용하려면 `ios/Config/Local.xcconfig`에 `DEVELOPMENT_TEAM = 실제_TEAM_ID`를 설정합니다. Team ID는 Apple Developer에서 확인하는 10자리 식별자이며 이메일 주소가 아닙니다.
2. 두 target에 App Groups capability를 추가하고 `group.com.pangjoong.buswidget`을 활성화합니다.
3. 앱과 실시간 현황 확장은 **시뮬레이터·실제 iPhone, Debug·Release/TestFlight 모두 `https://bus.pangjoong.com`**을 사용합니다.
4. 기본 설정에는 로컬 백엔드 실행이 필요 없습니다. `make xcode`로 프로젝트를 열고 실행 기기를 선택한 뒤 실행합니다. 다른 서버를 사용하려면 `Config/Local.xcconfig.example`을 `Config/Local.xcconfig`로 복사하고 SDK·구성별 `API_BASE_URL` 예시를 수정합니다.

앱 번들 ID는 `com.pangjoong.BusWidget`, 실시간 현황 확장은 `com.pangjoong.BusWidget.BusWidgetExtension`입니다. iOS는 임베드된 extension ID가 부모 앱 ID로 시작하도록 강제하므로 이 접두어 관계를 유지해야 합니다.

앱 아이콘은 `ios/BusWidgetApp/Assets.xcassets/AppIcon.appiconset`에 있습니다. 개인정보처리방침은 즐겨찾기 화면의 `더보기` 메뉴에서 열 수 있으며, 앱에 번들로 포함되어 오프라인에서도 읽을 수 있습니다.

## 개인정보 및 배포 준비

개인정보처리방침 원본은 `backend/app/content/privacy.json`입니다. 백엔드의 `GET /privacy`와 앱의 방침 화면은 이 파일을 함께 사용합니다. 내용을 수정하면 서버 재배포와 앱 재빌드가 필요합니다. 운영 서버에 반영한 뒤 App Store Connect의 개인정보처리방침 URL에 `https://bus.pangjoong.com/privacy`를 입력합니다. 문의 주소는 `isac7722@gmail.com`입니다.

`ios/Shared/PrivacyInfo.xcprivacy`는 앱과 실시간 현황 확장 번들에 각각 포함됩니다. App Group의 설정·도착 정보 공유를 위해 `UserDefaults` 사용 사유 `1C8F.1`을 선언합니다. 광고 추적은 하지 않지만, 서버의 IP 포함 접속 로그를 유지하므로 검색 기록, 제품 상호작용, 성능 및 기타 진단 데이터를 앱 기능 목적으로 선언했습니다. 원본 IP를 제거하지 않는 현재 동작을 기준으로 사용자와 연결된 데이터로 보수적으로 표시합니다. App Store Connect의 개인정보 응답은 매니페스트와 별개이므로 운영 환경을 확인한 뒤 동일하게 작성해야 하며, 현재 상태에서 단순히 '데이터를 수집하지 않음'으로 제출하지 않습니다.

현재 저장소에는 운영 프록시·호스팅 업체·로그 보관 기간 설정이 없습니다. 방침에 임의의 보관 일수를 적지 않았습니다. 정식 출시 전 실제 로그 보관·삭제 주기, 호스팅 및 이메일 처리에 따른 위탁·국외 처리 여부를 확인하고 방침을 구체화해야 합니다. `/privacy`는 데이터베이스와 Redis 조회 없이 응답하지만, 현재 서버 프로세스 시작에는 기존과 동일하게 두 서비스가 필요합니다.

선언 기준: [Apple의 개인정보 수집·IP 주소 안내](https://developer.apple.com/app-store/app-privacy-details/)와 [App Group UserDefaults 사용 사유](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

아이폰 전용 설정은 iPad 네이티브 지원을 제외합니다. App Store가 제공하는 iPhone 앱의 iPad 호환 실행까지 차단하는 설정은 아닙니다. App Store Connect의 Mac 및 Apple Vision 제공 여부도 출시 전에 확인합니다.

즐겨찾기 카드에는 정류장·방향과 버스 번호 배지가 표시됩니다. `버스 기다리기`를 눌러 오늘 기다릴 버스를 선택하고 대기를 시작합니다. 카드 아래 `자주 타는 정류장 추가`로 새 조합을 저장합니다.

홈 화면과 잠금 화면의 고정 위젯 및 위젯 표시 설정은 제거했습니다. 대기 중 표시되는 **실시간 현황과 Dynamic Island는 유지**합니다. 기존 위젯 설정은 즐겨찾기가 없는 기존 사용자에게 최초 1회 가져온 뒤 위젯 전용 설정·캐시를 정리합니다. 기존 즐겨찾기와 진행 중 대기는 유지됩니다. 확장 타깃과 번들 ID는 실시간 현황 및 업데이트 호환성을 위해 유지합니다.

## API

```text
GET /health
GET /privacy
GET /api/v1/stations/search?q=강남
GET /api/v1/stations/{station_id}
GET /api/v1/stations/{station_id}/arrivals?route_ids=100100341,100100360
```

- 도착 조회는 서울시 `getStationByUid`, 경기 연동 시 GBIS `getBusArrivalListv2`를 호출하고 Redis에 기본 30초간 캐시한 뒤 노선을 필터링합니다.
- 정류소의 노선 목록과 노선 선택 검증은 `getRouteByStation`의 전체 경유노선을 사용합니다. 서울시가 연계 제공하는 경기 노선과 도착 예측이 없는 노선도 포함하며, 목록은 도착정보와 별도로 기본 30초간 캐시합니다.
- `backend/.env`에 `GYEONGGI_BUS_API_KEY`를 설정하면 경기 정류소 이름·번호 검색과 경유노선·도착정보 직접 조회를 추가합니다. 공공데이터포털의 **경기도 정류소 조회와 버스도착정보 조회** 두 서비스 승인이 필요합니다. [설정·배포 안내](backend/README.md#경기버스-gbis-직접-연동)를 참고하세요.
- 기존 `station_id`는 5자리 ARS 번호를 유지하며, 경기 API에서 추가되는 정류소는 `gg:210000239`처럼 공급자와 9자리 노드 ID로 구분합니다. 검색 응답의 `station_id`를 그대로 상세·도착·실시간 현황 요청에 사용합니다.
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

`/docs`, `/redoc`, `/openapi.json`은 제공하지 않습니다.

## TestFlight 배포

최초 API 키·서명 설정 후 한 명령으로 iOS 테스트, 버전 증가, Release 빌드, 업로드와 Apple 처리 완료 확인을 실행합니다.

```bash
make testflight
```

App Store Connect의 **사용자 및 액세스 → 통합 → App Store Connect API → 팀 키**에서 발급한 Key ID, Issuer ID와 `.p8` 파일을 사용합니다. 개인 키는 저장소 밖에 보관하고 아래 예시를 복사한 뒤 실제 값을 입력합니다.

```bash
cp ios/Config/TestFlight.example.json ios/Config/TestFlight.local.json
```

설정 항목은 `key_id`, `issuer_id`, `key_path`이며, 같은 의미의 `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` 환경변수가 있으면 우선 적용합니다. 로컬 설정과 개인 키는 Git에서 제외됩니다.

```bash
make testflight-check        # 인증과 앱 접근 확인
make testflight              # iOS 테스트 → 빌드·업로드 → Apple 처리 확인
make testflight-status       # 마지막 업로드 상태 재확인, 재업로드하지 않음
make testflight-script-test  # 자동화 로직의 오프라인 테스트
```

앱과 실시간 현황 확장은 동일 버전과 운영 API 주소로 빌드됩니다. 프로젝트·원격·로컬 업로드 이력 중 가장 높은 앱 버전의 패치를 증가시키고 빌드 번호도 증가시킵니다. 업로드를 시도한 번호는 재사용하지 않습니다. Apple 처리 완료 후 프로젝트 버전을 반영하며 커밋·푸시는 자동 수행하지 않습니다.

결과와 단계별 로그는 `ios/build/testflight/<실행 시각>/`에 저장됩니다. 기본 30분 대기 후에도 처리가 끝나지 않으면 `make testflight-status`로 다시 확인하세요. 특정 기록은 `python3 ios/scripts/testflight.py status --run ios/build/testflight/실행폴더 --timeout 3600`으로 확인할 수 있습니다. 인증 정보 없이 실행 흐름만 확인하려면 `python3 ios/scripts/testflight.py --dry-run`을 사용합니다.

서명 인증서·프로파일은 Xcode 자동 서명을 사용합니다. 서명 실패 시 `archive.log`·`export.log`에서 권한과 App Group 설정을 확인하세요. 처리 완료는 Apple의 `VALID` 상태를 의미하며, 테스터 그룹 지정·외부 테스트 심사·App Store 출시 제출은 수행하지 않습니다. 수출 규정 준수 정보는 App Store Connect에서 별도로 확인합니다.

## 검증

백엔드:

```bash
make test-backend       # Docker만 필요, Go 검사·테스트와 임시 DB·Redis 자동 실행·정리
make test-backend-unit  # Docker 없이 단위·Python 응답 호환성 검사
```

iOS:

```bash
cd ios
xcodegen generate
xcodebuild -project BusWidget.xcodeproj -scheme BusWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

실기기에서는 즐겨찾기 저장·복원, 큰 글자·다크 모드, 대기 시작·종료, 잠금 화면·Dynamic Island의 실시간 현황과 APNs 갱신을 확인해야 합니다.

## 버스 기다리기 · 실시간 현황

저장한 노선을 최대 4개 선택해 함께 기다릴 수 있습니다. 잠금 화면에는 선택한 모든 노선의 도착 상황을, 작은 다이내믹 아일랜드에는 가장 빠른 도착 시간을 표시합니다. 앱에서 **N개 버스 기다리기**로 시작하고 **전체 대기 종료**로 중지합니다.

잠금 중 갱신에는 별도의 Apple Developer **APNs 키**와 서버 설정이 필요합니다. TestFlight 업로드용 App Store Connect 키로는 대체할 수 없습니다. [APNs 설정·Docker 실행·실기기 확인 방법](docs/live-activities.md)을 참고하세요.

### 지도에서 정류장 → 버스 선택 → 즐겨찾기

지도 또는 이름·번호 검색으로 정류장을 고른 뒤, 해당 정류장의 버스를 최대 4개 선택합니다. 정류장·버스 조합을 별명과 함께 즐겨찾기에 저장하고 다음에는 바로 기다릴 수 있습니다. 기존 위젯 설정은 첫 즐겨찾기로 가져옵니다. 오늘 기다릴 버스 선택은 저장된 즐겨찾기를 바꾸지 않습니다.

탐색은 서버의 `ROUTE_MAP_ENABLED` 설정으로 노출합니다. 지도는 DB에 반영된 서울·서울 버스 경유 경기 정류장을 표시합니다. 새 지도 API가 필요하므로 실제 서빙 서버를 먼저 업데이트해 주세요.

- `make routes-check`: 서울·경기 노선 서비스와 방향별 도착 API 연결 진단
- `make routes-smoke`: 실행 중인 서버의 검색·선택·도착 조회 확인
- `make test-route-ui`: 합성 API로 iOS 지도 선택 UI 테스트 (macOS/Xcode)

[API 계약·설정·서버 반영 절차](docs/design/route-map-api.md)

네이버 지도 SDK 설정과 시뮬레이터 확인 방법은 [네이버 지도 설정](docs/naver-maps.md)을 참고하세요.
