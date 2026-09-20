# 버스 기다리기 · 실시간 현황

저장한 정류소 화면에서 **N개 버스 기다리기**를 누르면 등록된 전체 노선(최대 4개)의 대기를 시작합니다. 상세 화면을 여는 것만으로 시작하지 않으며, 노선 행은 번호·방면·도착정보를 표시합니다. 노선 구성을 바꾸려면 **정류장·버스 변경**을 사용합니다. 즐겨찾기의 **바로 기다리기**는 전체 노선 대기를 즉시 시작합니다.

- 잠금 화면과 펼친 다이내믹 아일랜드: 선택한 모든 노선의 도착 시간 또는 상태를 한 카드에 표시합니다.
- 작은 다이내믹 아일랜드: 대기 중인 노선 중 예상 도착 시간이 가장 가까운 버스의 남은 시간을 표시합니다. 이미 종료된 노선은 제외하지만, 예정 시각이 지난 대기 중 버스는 `곧 도착`으로 유지합니다. 순위는 새 상태가 표시될 때 갱신됩니다.
- 앱: 노선별 상태를 확인하고 **전체 대기 종료**로 함께 종료합니다. 잠금 화면 카드를 누르면 앱으로 돌아옵니다.

하나 이상의 노선에 운행 중인 버스의 유효한 도착 정보가 있어야 시작합니다. 일부 노선에 정보가 없으면 해당 행에 **다시 연결 중**을 표시하고 나머지 노선은 계속 추적합니다. 모두 정보가 없으면 시작하지 않고 재시도 안내를 표시합니다. 기존 홈·잠금 화면 위젯 설정은 유지됩니다.

서버는 노선별 차량 ID를 추적해 다음 버스로 자동 전환하지 않습니다. 한 노선이 지나가도 다른 노선의 대기는 유지하고, 모든 노선의 대기가 끝나면 Live Activity를 종료합니다. 도착 예측이 0초여도 **곧 도착**을 유지합니다. 추적 차량이 예상 도착 시간 근처에 사라지고 뒤 차량이 확인되면 **통과 예상**으로 표시합니다. 탑승 여부를 감지하지 않습니다. 차량 ID가 없는 응답에서는 차량 교체를 판별할 수 없어 시간 제한이나 사용자 취소로 종료합니다.

앱 내부·잠금 화면·다이내믹 아일랜드 모두 `10:01`, `0:30`, `0:01`처럼 분:초로 표시합니다. 0초부터 **곧 도착**을 표시합니다. 대기 중인 동일 차량의 API 예상 시간이 늘어나거나 차량이 일시적으로 누락되어도 표시를 유지하고, 기존 **통과 예상** 판정 또는 취소·만료로 종료합니다. 실제 API 예상 시각은 통과 판정을 위해 별도로 갱신합니다. 조회가 실패해도 마지막 정상 도착 예정 시각을 유지하며, 새 응답이 오기 전에는 시간 경과만으로 뒤 버스의 예측으로 전환하지 않습니다. `업데이트 중`·`갱신 지연`·경과 시간 경고는 표시하지 않습니다. `updatedAt`은 원천 정보 시각으로 유지하며 캐시 조회나 재전송 시 현재 시각으로 바꾸지 않습니다.

서버는 각 대기에 10초 간격으로 푸시 전송을 시도합니다. 연결 오류·타임아웃에는 직전 실패 후 1초, 3초, 5초 간격으로 추가 3회 재시도하며, 모두 실패하면 10초 후 새 주기를 시작합니다. 성공 시 재시도 횟수를 초기화합니다. 1초 스케줄러가 Redis의 `next_push_at`·`push_retry`를 확인하며, 최대 32개 대기를 동시에 처리합니다. 재시도 중에는 같은 대기의 정기 전송을 겹치지 않습니다. APNs 429는 60초, 5xx 및 수정이 필요한 인증·요청 오류는 15분 대기합니다. 무효 토큰은 기존 규칙대로 중단합니다. 푸시 재시도만으로 버스 API를 다시 조회하지 않습니다.

실시간 데이터의 Redis 캐시는 5초이며 메타데이터 TTL은 별도로 유지합니다. 앱이 열려 있으면 동일 차량을 추적하는 `GET /api/v1/live-activities`로 10초마다 보완 조회합니다. 연결 경로 복구·앱 복귀 시 즉시 조회하고, 응답 `revision`으로 늦은 HTTP/푸시가 최신 상태를 덮어쓰는 것을 막습니다. 정상 푸시는 우선순위 5, 종료는 10입니다. 잠금 화면·다이내믹 아일랜드는 시스템 타이머로 매초 표시를 갱신하며 0에서 멈춥니다. 매초 푸시를 보내지 않습니다. 정상 전송 중에는 0초 시점에 맞춰 다음 푸시를 앞당기며, 원천 조회 없이 표시만 갱신할 때도 revision을 증가시킵니다. 0초 전환 시각은 ActivityKit의 `staleDate`/APNs `stale-date`로도 전달합니다. APNs 접수 성공은 단말 수신 확인이 아니며 실제 전달·렌더링 시점은 iOS/APNs가 결정합니다. 시스템 재렌더링·푸시 전달이 지연되면 0초에서 **곧 도착** 라벨로 전환하는 시점이 늦어질 수 있습니다.

즐겨찾기의 보이는 카드·상세 화면·찾기의 보이는 버스 행은 활성 화면에서만 10초마다 도착정보를 조회합니다. 정류장·노선·탑승 방향·노선 개정별 마지막 정상 응답을 메모리와 기기에 저장하며, 화면 이동 시 같은 데이터를 재사용합니다. 최대 128개 노선 항목을 보관하고 24시간 경과한 항목은 정리합니다. 서버 환경별 캐시를 분리합니다. 새 조회가 일부 노선에서만 실패하면 해당 노선의 마지막 성공 응답을 유지합니다. 화면의 선택·목록 순서·지도 위치·스크롤은 갱신으로 바뀌지 않습니다.

`기다리기`를 누르면 대기 화면을 먼저 열고 캐시로 미리보기를 표시합니다. 서비스 가능 여부와 도착 조회를 병행하고 푸시 토큰은 비동기 이벤트로 받습니다. 최초 서버 등록 중에는 시작 진행 상태를 표시하며, 실패 시 같은 화면에서 재시도할 수 있습니다. 자동 갱신에는 진행 안내를 추가하지 않습니다.

대기는 최대 1시간이며 서버가 종료 푸시를 보냅니다. 종료 카드는 약 1분 뒤 사라집니다. 서버 장애나 푸시 전달 실패로 종료가 늦어질 수 있습니다. 이때 앱에서 직접 종료할 수 있고, 다음 앱 활성화 때 만료된 활동을 정리합니다. 앱을 닫아도 서버 갱신은 계속되지만, 잠금 화면에서 사용자가 카드를 지운 사실을 서버가 즉시 알 수는 없습니다. 앱 재실행 또는 APNs 토큰 무효 응답/시간 제한에 따라 정리합니다.

## 1. Apple Developer 설정

TestFlight 업로드에 사용한 **App Store Connect API 키와 APNs 키는 서로 다릅니다**. Issuer ID도 사용하지 않습니다.

1. [Apple Developer 계정](https://developer.apple.com/account) → **Certificates, Identifiers & Profiles → Identifiers**에서 앱 ID `com.pangjoong.BusWidget`의 **Push Notifications**를 활성화합니다.
2. **Keys → +**에서 **Apple Push Notifications service (APNs)** 용도의 키를 만들고 `.p8`를 다운로드합니다. Key ID와 **Team ID**를 확인합니다. 현재 Xcode 프로젝트의 Team ID는 `K5M43RRH97`입니다.
3. 개발과 TestFlight를 모두 확인하려면 사용할 키에 **Sandbox와 Production** 환경 및 해당 앱의 권한이 있어야 합니다. 환경·토픽 제한 키를 사용한다면 배포 환경에 맞는 키를 서버에 설정합니다.
4. `.p8`는 서버에만 보관합니다. 앱·위젯 번들, Docker 이미지, Git에는 넣지 않습니다. 현재 서버의 `.config/*.p8` 파일은 `.gitignore`의 `*.p8` 규칙으로 제외됩니다. 다운로드는 한 번만 가능하므로 안전하게 보관합니다.

프로젝트에 `NSSupportsLiveActivities`, Push Notifications entitlement와 딥 링크가 추가되어 있습니다. Xcode의 자동 서명이 변경된 기능을 포함하는 프로비저닝 프로파일을 발급해야 합니다. 개발용 entitlement는 `development`이며, App Store 내보내기는 배포 프로파일에 따라 `production`으로 서명합니다. 앱은 내장 프로비저닝 프로파일에서 실제 환경을 읽으며, 해당 프로파일이 없는 TestFlight/App Store 설치는 Production을 사용합니다.

## 2. Go 서버 설정

로컬 실행이라면 `backend/.env`에 다음을 설정합니다.

```dotenv
APNS_KEY_ID=YOUR_APNS_KEY_ID
APNS_TEAM_ID=YOUR_TEAM_ID
APNS_KEY_PATH=/absolute/path/outside/repository/AuthKey_YOUR_APNS_KEY_ID.p8
APNS_BUNDLE_ID=com.pangjoong.BusWidget
```

Docker는 선택적 설정 파일을 함께 사용합니다. 현재 서버에서는 `backend/.env`에 `APNS_KEY_ID=V2LRALC8PH`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`를 설정하고 다음을 실행합니다. 호스트 키 경로는 `/home/pangjoong/dev/bus-alarm/.config/AuthKey_V2LRALC8PH.p8`가 기본값이며, 컨테이너에서는 `/run/secrets/apns_key`로 읽습니다.

```sh
docker compose -f docker-compose.yml -f docker-compose.apns.yml up --build -d
```

다른 위치의 키를 사용하려면 실행 전에 `APNS_KEY_HOST_PATH` 환경변수에 해당 파일의 절대경로를 지정합니다.

키 파일이 컨테이너의 `buswidget` 사용자에게 읽기 가능해야 합니다. 시작 로그의 `live_activities_enabled`와 다음 응답으로 활성화를 확인합니다.

```sh
curl --fail http://localhost:8000/api/v1/live-activities/availability
# {"available":true}
```

키 설정이 없으면 기존 API는 정상 동작하고, 실시간 현황 시작은 준비 중 안내를 표시합니다. 설정이 일부만 있거나 키 파일을 읽지 못하면 서버 시작이 실패하여 잘못 설정된 푸시를 조기에 발견할 수 있습니다. Apple 키 권한·서명 유효성은 실제 APNs 전송 시 확인됩니다. 서버에서 APNs의 HTTPS/HTTP2 연결이 가능해야 합니다.

**재배포·재시작에도 APNs 설정을 함께 적용하세요.** Make에서는 `APNS=1`로 추가 파일을 적용합니다. 실행 중인 서버의 백엔드만 반영하는 예:

```sh
make restart APNS=1
```

## 3. 실기기 검증

1. 서버를 위 설정으로 배포하고, `make testflight` 또는 Xcode로 기능이 포함된 앱을 설치합니다.
2. 운행 중인 정류소·노선을 저장하고 **버스 기다리기**를 누릅니다. iPhone 설정에서 앱의 **실시간 현황**을 허용해야 합니다. 일반 알림 권한 요청은 필요하지 않습니다.
3. 화면을 잠가 정류소·노선·카운트다운을 확인하고, 앱을 백그라운드로 둔 채 도착 정보 갱신을 확인합니다. 지원 모델에서는 다이내믹 아일랜드의 작은 표시와 길게 눌렀을 때의 확장 표시도 확인합니다.
4. **잠금 화면 카드 → 전체 대기 종료**, 도착 종료, 네트워크 단절 후 앱 재실행, 설정에서 실시간 현황 비활성화를 각각 확인합니다.
5. Release/TestFlight에서는 Production APNs로 갱신되는지 확인합니다. 시뮬레이터 빌드·단위 테스트만으로 Apple 서명과 실제 푸시 전달을 검증할 수는 없습니다.

개발 서버에서 `MOCK_ARRIVALS=true`를 사용하면 실시간 현황용 가상 버스가 5분 주기로 도착하므로 종료까지 확인할 수 있습니다. 기존 도착 API의 mock 응답은 유지됩니다. 원격 갱신까지 보려면 mock 모드에도 APNs 키와 푸시를 지원하는 설치 환경이 필요합니다. Xcode의 `BusWaitingLiveActivity` Preview에는 4개 노선의 정상·지연·도착 상태를 함께 표시하는 화면이 있습니다.

## API와 저장 방식

| 메서드·경로 | 용도 |
| --- | --- |
| `GET /api/v1/live-activities/availability` | 서버의 기능 설정 여부 |
| `POST /api/v1/live-activities` | 새 대기 등록 또는 회전한 ActivityKit 푸시 토큰 재등록 |
| `GET /api/v1/live-activities` | 현재 추적 세션 조회·보완 갱신 (등록과 동일한 인증 필요) |
| `DELETE /api/v1/live-activities` | 대기 종료, 중복 요청 허용 |

세션 GET·POST·DELETE에는 `Authorization: Bearer <64자리 무작위 hex>`가 필요합니다. 앱이 대기마다 보안 난수 32바이트를 생성하고 Keychain에 보관합니다. 이 값은 활동별 접근 권한이며, URL·활동 화면·요청 로그에 넣지 않습니다. 일반 APNs 기기 토큰이나 push-to-start 토큰이 아닌 **그 활동의 `pushToken`**을 등록해야 합니다.

실제 모드의 노선 검증·갱신은 정류장 상세와 같은 경유노선 목록을 사용합니다. 서울시가 연계 제공하는 경기 노선도 등록할 수 있습니다. `GYEONGGI_BUS_API_KEY` 설정 시 GBIS 직접 조회도 사용하며 경기 전용 정류장의 `gg:<노드 ID>`를 그대로 등록할 수 있습니다. GBIS 차량 식별자는 서버 내부에서만 사용합니다. mock 모드에서는 기존 DB의 노선 연결을 사용합니다.

POST 본문:

```json
{
  "station_id": "22001",
  "route_id": "100100341",
  "push_token": "ACTIVITYKIT_HEX_TOKEN",
  "environment": "production"
}
```

성공 응답에는 `expires_at`(Unix 초)과 `content`가 있습니다. `content`는 `status`, `arrivalAt`, `remainingStops`, `updatedAt`, 선택적 `revision`의 camelCase 필드를 가지며 APNs `content-state`와 동일합니다. 시간은 Foundation Date의 기본 인코딩을 사용하지 않고 **Unix 초 숫자**로 통일합니다.

세션은 Redis `liveactivity:session:<권한 토큰 SHA-256>`에 저장됩니다. 처음 정한 정류소·노선·환경과 만료 시간은 재등록으로 바뀌지 않습니다. 워커는 세션별 임대와 비교 후 저장으로 중복 처리 및 오래된 쓰기를 억제합니다. 종료 푸시 실패는 재시도하고, 성공 또는 무효 토큰 응답 시 푸시 토큰을 지웁니다. 취소 후 늦게 도착한 등록 요청은 거부합니다. 세션/종료 기록은 최대 약 65분 뒤 자동 만료됩니다. Redis 재시작 후에도 세션을 복원하려면 운영 Redis 영속화가 필요합니다.

앱은 종료 요청에 실패하면 Keychain에 보류 상태를 저장하고 다음 앱 활성화 때 재시도합니다. 등록과 상태 관리에 쓰는 토큰을 서버 로그에 기록하지 않습니다. 개인정보처리방침에도 선택한 정류소·노선과 활동별 푸시 정보의 임시 처리를 반영했습니다.

## 자동 검증

```sh
make test-backend
make test-ios
make testflight-script-test
```

기존 API 호환성, 실제 Redis의 등록·토큰 회전·취소·만료, 오래된 워커 쓰기 방지, APNs JWT 서명·헤더·오류 처리, 동일 차량 추적·데이터 지연·종료, Swift/APNs JSON 계약을 검증합니다.

## 다중 노선 API 계약

기존 단일 `route_id`/`boarding` 등록과 복원은 유지합니다. 새 앱은 `routes` 배열(1~4개, 중복 `route_id` 금지)로 등록합니다. 배열과 단일 노선 필드를 함께 보내면 400을 반환합니다. 노선 구성은 세션 중 변경할 수 없으며, 토큰 재등록은 차량 추적과 만료 시간을 유지합니다.

```json
{
  "station_id": "22001",
  "routes": [{"route_id": "100100341"}, {"route_id": "100100360"}],
  "push_token": "<ActivityKit token>",
  "environment": "production"
}
```

`POST /api/v1/live-activities`는 기존 정류소/노선 ID를 받습니다. `POST /api/v2/live-activities`는 `station_id`에 station reference, 각 배열 원소의 `boarding`에 기존 검증된 BoardingSelection을 받으며 방향과 정류장 방문 순서를 검증합니다. 삭제는 기존 `DELETE /api/v1/live-activities`를 공통으로 사용합니다.

응답과 APNs `content-state`는 기존 최상위 상태에 `routes: [{"routeId": "…", "content": {"status": "waiting", "arrivalAt": 1789426980, "remainingStops": 2, "updatedAt": 1789426800}}]`를 추가합니다. 최상위 시간은 가장 빠른 유효 도착 시간이고, 배열은 선택 순서를 유지합니다. 전체 종료 상태에 `finished`가 추가됩니다. `cancelled`/`expired`는 모든 행에 우선 적용됩니다.

앱 업데이트 전에 이 서버 변경을 먼저 배포해야 다중 노선 등록이 동작합니다. 기존 앱의 단일 노선 요청은 계속 지원합니다. 실제 APNs 전달과 잠금 화면의 갱신은 서명된 실기기에서 확인해야 합니다.

표시 제약: [Apple Live Activities 지침](https://developer.apple.com/design/human-interface-guidelines/live-activities)의 높이에 맞춰 4개 노선을 세로 행으로 표시합니다. Live Activity는 글꼴 확대를 기본 크기까지 제한하고 전체 크기의 접근성 글꼴은 앱에서 지원합니다.

참고: [ActivityKit 푸시 구현](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications), [APNs 토큰 인증](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
