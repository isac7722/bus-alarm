# 네이버 지도 설정

정류장 지도와 노선 지도는 NAVER Maps iOS SDK 3.24.0을 사용합니다. 정류장 마커와 버스·도착정보는 기존 서울·경기 API 및 서비스 DB에서 가져옵니다. 지도 교체를 위한 DB 갱신은 필요하지 않습니다.

## 최초 설정 (iOS를 빌드하는 Mac)

1. 네이버 클라우드 콘솔의 **Maps → Application**에서 **Dynamic Map**을 활성화하고 iOS Bundle ID에 `com.pangjoong.BusWidget`을 등록합니다.
2. 저장소 루트에서 다음을 실행합니다. 기존 파일이 있으면 복사하지 않습니다.

   ```sh
   cp -n ios/Config/NaverMaps.example.xcconfig ios/Config/NaverMaps.local.xcconfig
   open -e ios/Config/NaverMaps.local.xcconfig
   ```

3. 파일의 `NAVER_MAP_CLIENT_ID =` 뒤에 Client ID(Key ID)를 입력하고 저장합니다. **Client Secret은 앱이나 이 파일에 넣지 않습니다.** 로컬 파일은 Git에서 제외되며, Debug/Release가 함께 읽습니다. 다른 Mac/CI에서는 별도로 설정해야 합니다. CI는 동일한 파일을 생성하거나 Xcode build setting으로 값을 전달할 수 있습니다.
4. `make xcode`로 프로젝트를 생성하고 Xcode에서 BusWidget 스킴으로 실행합니다. SDK 패키지는 최초 빌드 시 다운로드됩니다. 시뮬레이터와 실제 iPhone 모두 API 기본 주소는 `https://bus.pangjoong.com`입니다.

키를 변경했다면 앱을 다시 빌드합니다. 로컬 키 파일을 커밋하지 않아도 최종 앱에는 Client ID가 포함됩니다. 콘솔의 Bundle ID 제한을 유지하세요.

## 확인

- **정류장 찾기**에서 네이버 지도 배경과 NAVER 로고가 보이는지 확인합니다.
- 오른쪽 `+`/`−` 또는 시뮬레이터 Option 드래그로 확대·축소하고, 지도를 옮긴 뒤 **이 지역 다시 찾기**를 누릅니다.
- 정류장 마커 → 원하는 버스 선택 → 즐겨찾기 저장/대기 시작을 확인합니다.
- `make test-ios`: iOS 단위 테스트.
- `make test-route-ui`: 합성 버스 API로 정류장 선택·즐겨찾기 등의 UI 회귀 테스트. 지도 SDK는 실제 네이버 서비스에 연결하므로 배경 지도 인증·표시는 별도로 확인합니다.

인증 실패 시 정류장 목록·검색을 계속 사용할 수 있습니다. 지도 배경이 표시되지 않으면 Client ID, Dynamic Map, Bundle ID, 사용 한도를 확인합니다. 공식 문서 기준 인증 오류 401은 키/클라이언트 유형/Bundle ID, 429는 서비스 선택/사용 한도, 800은 키 누락에 해당합니다.

지도 SDK는 앱에만 연결하며 실시간 현황 확장에는 포함하지 않습니다. SDK의 개인정보 매니페스트는 동적 프레임워크에 포함됩니다. 지도 제공자 변경에 맞춰 공용 개인정보처리방침도 수정했으므로 운영 `/privacy` 반영에는 서버 재배포가 필요합니다.

공식 문서: https://navermaps.github.io/ios-map-sdk/guide-ko/1.html
