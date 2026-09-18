# 지도 선택 API와 적용 방법

새 흐름은 `/api/v2`이며 기존 `/api/v1` 및 기존 위젯 설정을 유지한다. 지도에 표시할 정류장은 화면 범위(남·서·북·동 위도/경도)로 조회한다. 내 위치로 이동하면 그 주변 범위가 서버로 전송되며, 접속 로그에 남을 수 있다. 위치 권한 없이도 지도 이동과 이름·번호 검색을 사용할 수 있다.

## 운영 적용

1. 공공데이터포털에서 **서울특별시_노선정보조회 서비스**, **경기도_버스노선 조회** 승인과 인증키 연결을 확인한다. 기존 정류소·도착정보 승인과 별도다.
2. 실제 서빙 서버에서 최신 코드를 받은 뒤 `make routes-check`를 실행한다. Docker로 실행되므로 호스트 Go는 필요 없다. DB/Redis 쓰기나 APNs 등록은 하지 않는다.
3. 승인·연결 및 실제 방향을 확인한 후 `backend/.env`에 `ROUTE_MAP_ENABLED=true`를 설정한다. 기본값은 false다.
4. APNs 사용 서버는 `make restart APNS=1`로 backend를 재빌드하고 `make routes-smoke`로 확인한다. 원격 주소는 `make routes-smoke API_URL=https://bus.example.com`처럼 지정한다. 이 명령은 uv/Python을 사용한다.
5. 앱/위젯을 함께 빌드해 TestFlight/실제 기기에서 지도, 방향별 도착, Live Activity를 검증한다.

이 기능을 위해 `stations-update`를 다시 실행하거나 기존 DB를 초기화할 필요는 없다. `make restart`는 DB migration과 Excel import를 실행하지 않는다.

`ROUTE_MAP_ENABLED=false`는 새 검색 진입만 숨긴다. 이미 저장된 v2 선택의 도착 조회와 Live Activity는 계속 제공한다. v2 지원 전 서버로 되돌리는 방식의 롤백은 기존 v2 설정을 처리하지 못한다.

## 계약

- `route_ref`: 제공기관 + 노선 ID (`seoul:...`, `gg:...`). 노선 번호와 별개다.
- `station_ref`: 제공기관 + 정류장 node ID. 표시용 5자리 정류장 번호와 별개다.
- `boarding_id`: 노선·정류장·순번으로 구성된 방문 식별자. 앱은 그대로 보관한다.
- `route_revision`: 정류장 순서/방향/메타데이터의 변경 감지값. 다른 revision은 409 `ROUTE_CHANGED`로 재선택을 요청한다.
- 서울/경기 정류장 병합은 동일 node ID와 제공기관 조회 및 위치 일치를 검증한다. 5자리 번호나 이름만으로 병합하지 않는다.

| Method / Path | 요청과 응답 |
|---|---|
| GET `/capabilities` | `route_map`은 신규 탐색 활성화 설정. `providers.available`은 키 설정 여부이며 실제 승인을 보장하지 않음 |
| GET `/routes/search?q=9304` | `routes[]`: route_ref/name/region/kind/start/end. `providers[]`: provider/available/message/error_code. 일부 제공기관 실패를 별도 표시 |
| GET `/routes/{route_ref}` | route/revision/directions[]/stops[]. stop마다 탑승 선택 필드, station, next_stop, selectable, reason |
| GET `/routes/{route_ref}/geometry` | coordinates[{latitude,longitude}], source(`provider` 또는 `stops`). `stops`는 실제 도로 형상이 아님 |
| GET `/stations/nearby?south=37.53&west=127.09&north=37.54&east=127.10` | `stations[]`: MapStation, `truncated`: 추가 정류장 존재 여부. 각 축 범위 최대 0.12도, 최대 200개. 범위 초과는 400 `MAP_AREA_TOO_LARGE` |
| GET `/stations/resolve?id=05267` | 기존 정류장 ID를 MapStation으로 변환. 기존 정류장 검색 진입에 사용 |
| GET `/stations/{station_ref}/boarding-options?route_ref=...` | station/options[]/complete/warnings[]. route_ref는 DB에 없는 정류장을 검증된 노선 상세에서 해석하기 위한 선택적 값 |
| POST `/selections/validate` | 아래 SelectionRequest 검증 후 station/selections 반환. 서버에 사용자별 설정을 영속 저장하지 않음 |
| POST `/arrivals` | SelectionRequest → 기존 ArrivalsResponse 형태. route_id는 제공기관이 포함된 route_ref |
| POST `/live-activities` | station_id/route_id/boarding/push_token/environment. boarding은 아래 선택 항목. 기존 Bearer 세션 토큰 인증 유지 |
| DELETE `/live-activities` | 기존과 같은 Bearer 세션으로 종료. v1 DELETE도 동일 세션 저장소에 대한 종료를 지원 |

SelectionRequest 필드:

```json
{
  "station_ref": "gg:104000069",
  "selections": [
    {
      "boarding_id": "서버가 반환한 값",
      "route_ref": "gg:227000040",
      "route_revision": "서버가 반환한 값",
      "route_name": "9304",
      "station_ref": "gg:104000069",
      "sequence": 1,
      "direction_id": "서버가 반환한 값",
      "direction": "서버가 반환한 방면"
    }
  ]
}
```

위 순번은 요청 형태 설명용이다. 실제 9304 순번·방면을 하드코딩하지 않는다. 한 정류장, 1~4개 노선, 한 노선당 한 순번을 검증하며 클라이언트가 보낸 이름·방면 텍스트는 서버 값으로 정규화한다.

## 방향별 조회와 캐시

- 경기: `getBusArrivalItemv2`의 stationId/routeId/staOrder를 사용하고 응답의 세 값이 요청과 같아야 한다.
- 서울: `getArrInfoByRouteAll` 응답에서 busRouteId/stId/staOrd가 일치하는 단일 항목만 선택한다. 기존 정류장 전체 조회로 방향을 대체하지 않는다.
- 경기 방향 그룹은 검증 가능한 turnSeq와 기종점으로 나눈다. 서울은 경유 정류장의 direction을 사용한다. 불명확하면 정류장을 선택 불가로 표시한다.
- 노선 API 1시간, 검색/경유노선 5분, 도착 응답 5초의 성공 응답 캐시를 사용한다. 동일 조회를 합치고 정류장의 노선 상세는 최대 4개씩 조회한다.
- Live Activity 세션·조회 묶음에는 boarding_id와 revision을 보존해 반대 방향의 차량이 섞이지 않게 한다.
- iOS 도착 캐시는 설정 버전·정류장·노선·순번·revision이 일치할 때만 표시한다. 이전 캐시는 v1 설정과 정류장·노선 집합이 일치할 때만 사용한다.

## 검증

```bash
make test-backend
make test-ios SIMULATOR="iPhone 17 Pro"
make test-route-ui SIMULATOR="iPhone 17 Pro"
```

`test-route-ui`는 localhost:8767에 합성 API를 띄우고 전용 Xcode scheme을 실행한다. 앱 저장소는 실행마다 격리하며 실제 정류장 설정과 API 키를 사용하지 않는다. 기본/가로/어두운 모드·큰 글씨에서 선택과 저장을 검증하고 XCTest 화면 첨부를 남긴다. 테스트 URL/저장소 주입은 Debug 빌드에만 포함된다.

합성 fixture 테스트는 실제 운행 검증을 대신하지 않는다. 위치 권한 실제 프롬프트, VoiceOver 읽기 순서, 물리적 승강장 위치, TestFlight APNs 푸시는 실제 기기에서 확인해야 한다.

## 2026-09-17 실호출 확인

같은 공공데이터포털 계정의 키로 서울·경기 노선 조회 승인이 반영된 것을 확인했다. `routes-check` 결과 `success: true`이며 서울 370번과 경기 9304번 모두 노선 상세와 선택한 순번의 도착 조회가 정상 응답했다.

- 경기 9304: `gg:227000040`, 강변역 `gg:104000069`, 표시 번호 `05267`, 경유 순번 `25`, 회차 후 `inbound`.
- 해당 응답의 방면은 `BRT공영버스차고지(경유) 방면`, 다음 정류장은 `현대아파트앞`이다. 앱은 서버 응답을 표시하며 예시 방면을 하드코딩하지 않는다.
- 노선 목록에서 서울 정류장 mobileNo가 빠지는 경우를 확인했다. 정확한 node ID로 정류소 항목을 조회해 표시 번호를 보완한다. `(경유)`·`(미정차)` 지점은 지도/목록에 남기되 탑승 선택은 막는다.
- 실제 공개 응답의 식별 필드만 보존한 `verified-9304-*.xml` fixture로 이 사례를 재검증한다. 인증키·차량·업체 연락처는 포함하지 않는다.

원격 서빙 서버 배포와 TestFlight 업로드는 별도다. 자동 검사 통과가 실제 기기의 지도 품질·위치 권한·APNs 전달 확인을 대신하지 않는다.

## 정류장 중심 탐색과 즐겨찾기

- 신규 사용자는 **정류장 찾기** 지도에서 시작한다. 저장한 조합이 있으면 **즐겨찾기**가 먼저 열린다.
- 지도 핀/목록 → 정류장 번호 확인 → 버스별 방면·다음 정류장 확인 → 최대 4개 선택 → 즐겨찾기 저장 또는 기다리기. 도착예측이 없는 노선도 선택·저장할 수 있다.
- 지도는 현재 DB의 서울 및 서울 버스가 경유하는 경기 정류장을 조회한다. 경기도 전체 정류장 수집 기능은 아니다. 동일 이름의 반대편 정류장은 node ID로 구분하고 `(경유)`·`(미정차)` 지점은 지도 탐색에서 제외한다. 이름·번호 검색은 기존 검색 API를 사용한다.
- 즐겨찾기는 정류장·노선·방향 조합과 선택적 별명을 기기에 저장한다. 기존 위젯 설정은 최초 한 번 첫 즐겨찾기로 가져온다. 마지막 즐겨찾기를 삭제해도 다시 복원하지 않는다.
- 즐겨찾기 상세에서 **N개 버스 기다리기**를 누르면 저장한 전체 노선으로 대기를 시작한다. 임시 선택·해제는 제공하지 않으며 구성 변경은 **정류장·버스 변경**으로 저장한다.
- 활성 대기는 상단 배너로 다시 열 수 있다. 다른 조합을 시작하려면 기존 대기를 종료한다. 도착 순서로 목록을 재배치하지 않고, 선택한 대기 중 버스 중 가장 가까운 도착을 표시한다. 남은 초를 올림한 분 단위로 표시하며, 30초 이하부터 예정 시각이 지난 뒤까지 ‘곧 도착’을 유지한다. 갱신 실패 시 마지막 예정 시각을 사용한다.
- 큰 글씨·가로 화면에서는 목록을 우선 제공한다. 빈 검색 결과와 조회 오류를 구분하며 재시도할 수 있다.

새 `/stations/nearby` API를 사용하므로 **앱 테스트 전에 실제 서빙 서버도 이 코드로 업데이트**해야 한다. DB 스키마 변경은 없다. 기존 정류장 데이터가 이미 반영됐다면 재가져오기는 필요 없다.

```bash
# 실제 서빙 서버: 이 변경이 포함된 코드를 받은 후
make test-backend
make restart APNS=1
curl 'http://127.0.0.1:8000/api/v2/stations/nearby?south=37.53&west=127.09&north=37.54&east=127.10'

# Mac: 앱은 기존처럼 https://bus.pangjoong.com 사용
make test-ios
make test-route-ui
make xcode
# Xcode에서 시뮬레이터를 선택하고 실행(⌘R)
```

지도 범위가 현재 위치 주변을 포함하고 접속 로그와 연결될 수 있어, 개인정보 매니페스트에 위치 데이터의 앱 기능 목적 처리를 선언했다. 선언 키는 [Apple 데이터 유형 문서](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)를 따른다.

### 도착정보 자동 갱신 계약

- 활성 화면의 즐겨찾기 카드·상세·찾기 버스 행은 10초마다 재조회한다. 숨겨진 화면·행의 반복 조회는 중단한다.
- V2 도착 응답의 선택적 `route_updated_at`은 노선 ID별 원천 시각이며, `failed_route_ids`는 이번 조회에서 실패한 노선 ID다. 정상 노선은 즉시 반영하고 실패한 노선만 마지막 정상 캐시를 유지한다. 전부 실패하면 오류 응답을 반환한다.
- 확정된 빈 예측은 정상 응답이므로 이전 예측을 지운다. 캐시 조회·재전송은 원천 시각이나 절대 도착 예정 시각을 앞으로 이동시키지 않는다.
- `GET /api/v1/live-activities`는 기존 활동의 Bearer 인증으로 추적 상태를 반환한다. 일반 도착정보 조회로 대기 차량을 교체하지 않는다. 상태의 `revision`은 서버의 변경 순서이며 원천 데이터 시각인 `updatedAt`과 구분한다.
