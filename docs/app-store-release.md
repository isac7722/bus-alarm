# 버스 위젯 App Store 배포 진행 기록

작성일: 2026-09-16

이 문서는 2026-09-15에 진행한 배포 대화의 설정, 완료 내역, 다음 작업을 정리한 문서입니다. 이후 변경된 코드나 운영 서버 상태를 새로 검증한 결과는 아닙니다.

## 앱 정보

| 항목 | 값 |
|---|---|
| 앱 이름 | 버스 위젯 |
| 개발자 계정·문의 이메일 | `isac7722@gmail.com` |
| Apple Developer Team ID | `K5M43RRH97` |
| 앱 Bundle ID | `com.pangjoong.BusWidget` |
| 위젯 Bundle ID | `com.pangjoong.BusWidget.BusWidgetExtension` |
| App Group | `group.com.pangjoong.buswidget` |
| API 주소 | `https://bus.pangjoong.com` |
| 지원 대상 | iPhone |
| 기본 언어 | 한국어 |
| 등록 시 안내한 SKU | `buswidget-ios` |
| 업로드 완료 빌드 | `1.0 (1)` |
| TestFlight 내부 테스트 그룹 | 개인 테스트 |

## 전체 진행 순서

서명 설정 → App Store Connect 앱 등록 → 빌드 업로드 → TestFlight 실사용 확인 → 스토어 정보 작성 → 심사 제출 → 정식 출시

현재는 **TestFlight 설치·실행 확인까지 완료했고, 스토어 기본정보 입력을 안내한 상태**입니다. 심사 제출과 정식 출시는 아직 완료하지 않았습니다.

## 완료한 작업

### 1. 앱 배포 준비

- Debug와 Release의 API 주소를 `https://bus.pangjoong.com`으로 설정했습니다.
- iPhone 전용으로 빌드하도록 설정했습니다.
- 차분한 회색 배경과 반투명 유리 질감의 버스 아이콘을 적용했습니다.
- 개인정보 매니페스트를 앱과 위젯에 추가했습니다.
- 개인정보처리방침을 작성하고, 앱에서 오프라인으로 읽을 수 있도록 포함했습니다.
- 백엔드에 개인정보처리방침 페이지 `/privacy`를 추가했습니다.
- 서울시 API 인증키가 노출되는 HTTP 클라이언트 요청 로그를 끄도록 수정했습니다.
- 사용자 선택에 따라 일반 서버 접속 로그는 유지하고, IP 주소·검색 요청 등의 기록을 개인정보처리방침에 명시했습니다.

관련 파일:

- 아이콘: `ios/BusWidgetApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- 아이콘 제작 기록: [app-icon.md](app-icon.md)
- 개인정보 매니페스트: `ios/Shared/PrivacyInfo.xcprivacy`
- 개인정보처리방침 원본: `backend/app/content/privacy.json`
- iOS 프로젝트 생성 설정: `ios/project.yml`

개인정보 매니페스트는 Apple에 데이터 처리 내용과 특정 API의 사용 사유를 알리는 파일입니다. 앱과 위젯의 설정 공유를 위한 `UserDefaults` 사용 사유로 `1C8F.1`을 선언했습니다.

회원가입은 없습니다. 정류장 지도 기능은 화면 범위를 서버로 전송하며, 내 위치를 누르면 현재 위치 주변 지역이 이 범위에 포함됩니다. 지도 범위를 포함한 서버 접속 로그가 남을 수 있으므로, App Store Connect에서 단순히 **‘데이터를 수집하지 않음’**으로 답변하지 않도록 안내했습니다. 개인정보 응답은 실제 배포 버전과 서버 동작을 기준으로 작성해야 합니다.

### 2. 개발자 계정 및 서명 설정

1. Apple Developer에서 Team ID `K5M43RRH97`을 확인했습니다.
2. `ios/project.yml`에 Team ID를 설정했습니다.
3. 앱과 위젯의 Debug·Release 설정에 같은 Team ID와 자동 서명이 적용됨을 확인했습니다.
4. Xcode의 **Settings → Apple Accounts**에 개발자 계정을 연결했습니다.
5. 첫 서명 빌드에서 `PLA Update available` 오류가 발생했습니다.
6. 사용자가 Apple Developer에서 최신 Program License Agreement에 동의했습니다.
7. 재시도 후 서명된 Archive 생성에 성공했습니다.
8. 앱과 위젯의 서명, Team ID, App Group, 프로비저닝 프로파일을 확인했습니다.

이메일 주소는 Team ID를 대신할 수 없습니다.

### 3. App Store Connect 앱 등록

[App Store Connect](https://appstoreconnect.apple.com/)의 **앱 → ＋ → 신규 앱**에서 다음 정보로 등록하도록 안내했고, 사용자가 생성 완료를 확인했습니다.

| 항목 | 안내한 입력값 |
|---|---|
| 플랫폼 | iOS |
| 이름 | 버스 위젯 |
| 기본 언어 | 한국어 |
| 번들 ID | `com.pangjoong.BusWidget` |
| SKU | `buswidget-ios` |
| 사용자 액세스 | 전체 액세스 |

### 4. 빌드 업로드

서명된 Archive를 App Store Connect에 업로드했습니다.

- 업로드 결과: `Upload succeeded`, `EXPORT SUCCEEDED`
- App Store Connect에서 확인된 버전·빌드: `1.0 (1)`
- Build Uploads 상태: `Complete`

업로드 당시 사용한 임시 경로는 `/tmp/BusWidget-signed-release.xcarchive`입니다. 임시 파일은 삭제될 수 있으므로 다음 배포 때는 현재 코드로 Archive를 다시 생성해야 합니다.

### 5. 암호화 규정 준수 답변

처리된 빌드에 `Missing Compliance`가 표시되어 다음 순서로 진행했습니다.

1. `Missing Compliance` 옆 **Manage**를 선택했습니다.
2. 암호화 알고리즘 질문에서 **None of the algorithms mentioned above**를 선택하도록 안내했습니다.
3. 사용자가 저장 완료를 확인했습니다.

당시 코드를 확인한 결과, 별도 암호화 구현 없이 Apple의 `URLSession`을 통한 HTTPS 통신을 사용했습니다. 이후 암호화 기능이나 외부 라이브러리가 추가되면 답변을 다시 검토해야 합니다.

### 6. 내부 테스트 그룹 설정

1. **TestFlight → INTERNAL TESTING → ＋**에서 `개인 테스트` 그룹을 생성했습니다.
2. 본인 계정 `isac7722@gmail.com`을 테스터로 추가했습니다.
3. 그룹에 `1.0 (1)` 빌드를 추가했습니다.
4. 화면에서 그룹 1개, 테스터 1명이 연결된 상태를 확인했습니다.

`Individual Testers (0)`이어도 그룹을 통해 테스터가 연결되어 있으면 별도 추가할 필요가 없습니다.

테스트 안내 문구:

```text
- 정류소 검색
- 노선 저장
- 홈 화면 및 잠금 화면 위젯의 버스 도착 정보 확인
```

### 7. 아이폰 설치

아이폰에 TestFlight를 설치하고 초대 메일을 통해 앱을 설치하도록 안내했습니다. 사용자가 **설치와 실행 성공**을 확인했습니다.

정류소 검색·노선 저장·위젯 갱신 등의 전체 실사용 검증 완료 여부는 별도 확인이 필요합니다.

## 지금 할 일: 8단계 — 스토어 기본정보 입력

1. App Store Connect에서 **버스 위젯 → Distribution**을 선택합니다.
2. 왼쪽 **General → App Information**을 엽니다.
3. 아래처럼 입력하고 **Save**를 누릅니다.

| 항목 | 입력값 |
|---|---|
| Name | 버스 위젯 |
| Subtitle | 서울 버스 도착정보를 홈·잠금 화면에서 |
| Primary Category | Navigation — 내비게이션 |
| Secondary Category | 비워두기 |

이 단계의 저장 완료는 아직 대화에서 확인되지 않았습니다. 완료하면 다음으로 **연령 등급 설정**을 진행합니다.

## 정식 제출 전 남은 작업

- [ ] 스토어 기본정보 저장
- [ ] 연령 등급 질문에 실제 앱 기능 기준으로 답변
- [ ] 개인정보 수집 항목 작성
- [ ] 운영 로그 보관·삭제 주기와 호스팅 관련 처리 내용 확인 및 방침 구체화
- [ ] 개인정보처리방침 웹페이지 공개 및 접속 확인
- [ ] 앱 지원 페이지와 지원 URL 준비
- [ ] iPhone 스크린샷 준비
- [ ] 앱 설명, 키워드, 저작권, 심사 연락처와 심사 메모 작성
- [ ] 가격과 출시 국가 설정
- [ ] 정류소 검색, 노선 저장, 홈·잠금 화면 위젯을 실제 기기에서 검증
- [ ] 제출할 빌드 선택 — 현재 코드 변경사항이 필요하면 새 빌드 업로드
- [ ] 첫 버전의 출시 옵션을 수동 출시로 설정
- [ ] 심사 제출
- [ ] 승인 후 서버 상태를 확인하고 정식 출시

### 개인정보처리방침 URL 확인 기록

2026-09-15 확인 당시 결과:

| URL | 결과 |
|---|---|
| `https://bus.pangjoong.com/health` | HTTP 200 |
| `https://bus.pangjoong.com/privacy` | HTTP 404 |

정식 심사 전 운영 서버에 `/privacy` 페이지를 반영하고 실제 접속되는지 다시 확인해야 합니다. 위 결과는 당시 기록이며 현재 상태를 보장하지 않습니다.

## Apple 공식 안내

- [Team ID 확인](https://developer.apple.com/help/glossary/team-id/)
- [신규 앱 등록](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [빌드 업로드](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [암호화 수출 규정 안내](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
- [내부 테스터 추가](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [앱 정보 입력](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [앱 개인정보 안내](https://developer.apple.com/app-store/app-privacy-details/)
- [출시 옵션 설정](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option)
