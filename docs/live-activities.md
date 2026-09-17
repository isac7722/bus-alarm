# 버스 기다리기 · 실시간 현황

저장한 정류소 화면에서 노선을 하나 선택하고 **버스 기다리기**를 누르면 잠금 화면과 지원 기기의 다이내믹 아일랜드에 도착 상황이 표시됩니다. **대기 종료**로 중지할 수 있고, 잠금 화면의 **대기 관리**를 누르면 앱으로 돌아옵니다. 한 번에 한 노선을 기다립니다. 기존 홈·잠금 화면 위젯과 별개이며, 실시간 현황을 켜도 위젯 설정은 유지됩니다.

운행 중인 첫 번째 버스의 유효한 도착 정보가 있을 때 시작합니다. 서울시 응답의 차량 ID를 서버 내부에서 추적해 다음 버스로 자동 전환하지 않습니다. 서버에서 도착 시간이 0인 최신 정보를 받으면 종료합니다. 추적 차량이 예상 도착 시간 근처에 사라지고 뒤 차량이 확인되면 **지나간 것으로 예상**한다고 표시한 뒤 종료합니다. 탑승 여부를 감지하지 않습니다. 차량 ID가 없는 응답에서는 차량 교체를 판별할 수 없어 최신 도착 정보 또는 시간 제한에 따라 종료합니다.

정보가 90초 이상 오래되거나 조회에 실패하면 갱신 지연을 표시합니다. 예상 시간이 지났다는 이유만으로 도착을 확정하지 않습니다. 서버는 30초 간격으로 갱신을 시도하며, 같은 작업 주기에 같은 정류소 요청을 공유합니다. 실제 전달 시점과 표시 빈도는 iOS/APNs가 결정합니다. 매초 바뀌는 카운트다운은 기기에서 계산합니다.

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
4. **대기 관리 → 대기 종료**, 도착 종료, 네트워크 단절 후 앱 재실행, 설정에서 실시간 현황 비활성화를 각각 확인합니다.
5. Release/TestFlight에서는 Production APNs로 갱신되는지 확인합니다. 시뮬레이터 빌드·단위 테스트만으로 Apple 서명과 실제 푸시 전달을 검증할 수는 없습니다.

개발 서버에서 `MOCK_ARRIVALS=true`를 사용하면 실시간 현황용 가상 버스가 5분 주기로 도착하므로 종료까지 확인할 수 있습니다. 기존 도착 API의 mock 응답은 유지됩니다. 원격 갱신까지 보려면 mock 모드에도 APNs 키와 푸시를 지원하는 설치 환경이 필요합니다. Xcode의 `BusWaitingLiveActivity` Preview에는 정상·지연·도착 화면이 있습니다.

## API와 저장 방식

| 메서드·경로 | 용도 |
| --- | --- |
| `GET /api/v1/live-activities/availability` | 서버의 기능 설정 여부 |
| `POST /api/v1/live-activities` | 새 대기 등록 또는 회전한 ActivityKit 푸시 토큰 재등록 |
| `DELETE /api/v1/live-activities` | 대기 종료, 중복 요청 허용 |

POST와 DELETE에는 `Authorization: Bearer <64자리 무작위 hex>`가 필요합니다. 앱이 대기마다 보안 난수 32바이트를 생성하고 Keychain에 보관합니다. 이 값은 활동별 접근 권한이며, URL·활동 화면·요청 로그에 넣지 않습니다. 일반 APNs 기기 토큰이나 push-to-start 토큰이 아닌 **그 활동의 `pushToken`**을 등록해야 합니다.

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

성공 응답에는 `expires_at`(Unix 초)과 `content`가 있습니다. `content`는 `status`, `arrivalAt`, `remainingStops`, `updatedAt`의 camelCase 필드를 가지며 APNs `content-state`와 동일합니다. 시간은 Foundation Date의 기본 인코딩을 사용하지 않고 **Unix 초 숫자**로 통일합니다.

세션은 Redis `liveactivity:session:<권한 토큰 SHA-256>`에 저장됩니다. 처음 정한 정류소·노선·환경과 만료 시간은 재등록으로 바뀌지 않습니다. 워커는 세션별 임대와 비교 후 저장으로 중복 처리 및 오래된 쓰기를 억제합니다. 종료 푸시 실패는 재시도하고, 성공 또는 무효 토큰 응답 시 푸시 토큰을 지웁니다. 취소 후 늦게 도착한 등록 요청은 거부합니다. 세션/종료 기록은 최대 약 65분 뒤 자동 만료됩니다. Redis 재시작 후에도 세션을 복원하려면 운영 Redis 영속화가 필요합니다.

앱은 종료 요청에 실패하면 Keychain에 보류 상태를 저장하고 다음 앱 활성화 때 재시도합니다. 등록과 상태 관리에 쓰는 토큰을 서버 로그에 기록하지 않습니다. 개인정보처리방침에도 선택한 정류소·노선과 활동별 푸시 정보의 임시 처리를 반영했습니다.

## 자동 검증

```sh
make test-backend
make test-ios
make testflight-script-test
```

기존 API 호환성, 실제 Redis의 등록·토큰 회전·취소·만료, 오래된 워커 쓰기 방지, APNs JWT 서명·헤더·오류 처리, 동일 차량 추적·데이터 지연·종료, Swift/APNs JSON 계약을 검증합니다.

참고: [ActivityKit 푸시 구현](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications), [APNs 토큰 인증](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).
