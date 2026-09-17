# 지도 선택 API와 적용 방법

새 흐름은 `/api/v2`이며 기존 `/api/v1` 및 기존 위젯 설정을 유지한다. 위치 좌표는 지도에 제공하지만 사용자의 현재 위치를 API로 전송하지 않는다.

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
- 노선 API 1시간, 검색/경유노선 5분, 도착 응답 30초의 성공 응답 캐시를 사용한다. 동일 조회를 합치고 정류장의 노선 상세는 최대 4개씩 조회한다.
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
