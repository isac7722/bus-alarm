Bus Widget — 개발 상세 명세서

1. 프로젝트 개요

1.1 프로젝트명

BusWidget

1.2 목적

사용자가 자주 이용하는 버스 정류장과 버스 노선을 등록하면 iPhone 홈 화면의 Widget에서 앱을 실행하지 않고 다음 정보를 확인할 수 있도록 한다.

예:

┌─────────────────────────┐
│ 🚌 강남역                │
│                         │
│ 341번          3분       │
│ 360번          7분       │
│ 740번         15분       │
│                         │
│ 업데이트 09:27           │
└─────────────────────────┘

1.3 핵심 UX

사용자는 앱을 열지 않고 홈 화면에서:

1. 어떤 정류장인지 확인
2. 등록한 버스 노선 확인
3. 각 버스의 도착 예정시간 확인
4. 도착 예정시간이 감소하는 countdown 확인

을 할 수 있어야 한다.

⸻

2. 핵심 설계 원칙

2.1 실시간 API 조회와 countdown을 분리한다

가장 중요한 설계 원칙이다.

서울시 API에서:

{
  "route": "341",
  "arrival_seconds": 180
}

를 받았다고 해서 Widget에 "3분"이라는 문자열을 저장하지 않는다.

대신:

현재 시각 = 09:27:00
도착 예정 = 09:30:00

처럼 arrivalAt을 저장한다.

Widget은 arrivalAt을 기반으로 남은 시간을 표시한다.

따라서 API를 매분 호출하지 않아도:

09:27 → 3분
09:28 → 2분
09:29 → 1분
09:30 → 도착

형태의 UI를 구현할 수 있다.

Apple은 WidgetKit에서 위젯이 계속 실행되지 않는 상황에서도 dynamic date를 사용해 countdown/timer를 표시할 수 있도록 지원한다. (Apple Developer)

⸻

3. 전체 시스템 아키텍처

                       ┌──────────────────────┐
                       │ 서울시 버스 Open API │
                       │                      │
                       │ 정류장 정보           │
                       │ 노선 정보             │
                       │ 도착 예정 정보        │
                       └──────────┬───────────┘
                                  │
                                  │ HTTPS
                                  ↓
                    ┌─────────────────────────┐
                    │       FastAPI           │
                    │                         │
                    │ Bus API Client          │
                    │ Station Service         │
                    │ Arrival Service         │
                    │                         │
                    │ Cache                   │
                    └────────────┬────────────┘
                                 │
                                 │ HTTPS JSON
                                 ↓
┌────────────────────────────────────────────────────┐
│                      iPhone                        │
│                                                    │
│  ┌─────────────────┐        ┌──────────────────┐  │
│  │ SwiftUI App     │        │ Widget Extension │  │
│  │                 │        │                  │  │
│  │ 정류장 검색      │        │ WidgetKit        │  │
│  │ 정류장 선택      │───────▶│ Timeline         │  │
│  │ 노선 선택        │        │ Dynamic Date     │  │
│  │ 설정 관리        │        │                  │  │
│  └─────────────────┘        └──────────────────┘  │
│            │                         │             │
│            └──────── App Group ─────┘             │
│                      Shared Data                   │
└────────────────────────────────────────────────────┘

⸻

4. 기술 스택

Backend

* Python 3.12+
* FastAPI
* Pydantic v2
* httpx
* pytest
* pytest-asyncio
* Redis 선택사항
* Docker
* uv

iOS

* Swift
* SwiftUI
* WidgetKit
* AppIntents
* URLSession
* App Groups
* Swift Testing 또는 XCTest

Infrastructure

MVP:

FastAPI
   ↓
Docker
   ↓
AWS ECS/Fargate 또는 Lambda

단, MVP 개발 초기에는 로컬 Docker 환경으로 시작한다.

Production에서는 AWS를 사용한다.

⸻

5. Backend 책임

FastAPI 서버는 다음 책임을 가진다.

반드시 담당

* 서울시 API 인증키 보호
* 서울시 API 호출
* 서울시 API 응답 정규화
* 정류장 검색
* 정류장 상세 조회
* 버스 도착정보 조회
* 오류 처리
* API timeout 처리
* 외부 API 응답 캐싱

Backend에서 하지 않는 것

Backend는 사용자별 Widget UI 상태를 관리하지 않는다.

또한 countdown 자체를 계산해서:

{
  "remaining": 3
}

형태로 내려주는 것을 기본 방식으로 사용하지 않는다.

대신:

{
  "arrival_at": "2026-08-12T09:30:00+09:00"
}

형태를 우선한다.

⸻

6. Backend 프로젝트 구조

backend/
├── app/
│   ├── main.py
│   │
│   ├── api/
│   │   ├── router.py
│   │   └── routes/
│   │       ├── health.py
│   │       ├── stations.py
│   │       └── arrivals.py
│   │
│   ├── core/
│   │   ├── config.py
│   │   ├── logging.py
│   │   └── exceptions.py
│   │
│   ├── schemas/
│   │   ├── station.py
│   │   └── arrival.py
│   │
│   ├── services/
│   │   ├── station_service.py
│   │   └── arrival_service.py
│   │
│   ├── clients/
│   │   └── seoul_bus_client.py
│   │
│   └── cache/
│       └── cache.py
│
├── tests/
│   ├── api/
│   ├── services/
│   └── clients/
│
├── Dockerfile
├── pyproject.toml
├── .env.example
└── README.md

⸻

7. 환경변수

APP_ENV=local
SEOUL_BUS_API_KEY=
SEOUL_BUS_API_BASE_URL=
REDIS_URL=
CACHE_TTL_SECONDS=30
HTTP_TIMEOUT_SECONDS=5

실제 API Key는 Git에 절대 커밋하지 않는다.

⸻

8. Backend API

8.1 Health Check

GET /health

Response:

{
  "status": "ok"
}

⸻

9. 정류장 검색 API

Endpoint

GET /api/v1/stations/search?q={keyword}

예:

GET /api/v1/stations/search?q=강남역

Response:

{
  "stations": [
    {
      "station_id": "123456",
      "ars_id": "22-001",
      "name": "강남역",
      "direction": "역삼역 방면",
      "latitude": 37.4979,
      "longitude": 127.0276
    }
  ]
}

요구사항

* 검색어가 비어 있으면 400
* 서울시 API의 원본 필드명을 iOS가 직접 의존하지 않도록 Backend에서 정규화
* 결과는 최대 20개
* 검색 결과가 없으면 빈 배열 반환
* 외부 API 오류 시 적절한 5xx 응답

⸻

10. 정류장 상세 API

GET /api/v1/stations/{station_id}

Response:

{
  "station": {
    "station_id": "123456",
    "ars_id": "22-001",
    "name": "강남역",
    "direction": "역삼역 방면",
    "latitude": 37.4979,
    "longitude": 127.0276
  },
  "routes": [
    {
      "route_id": "341",
      "route_name": "341"
    },
    {
      "route_id": "360",
      "route_name": "360"
    }
  ]
}

⸻

11. 버스 도착정보 API

Endpoint

GET /api/v1/stations/{station_id}/arrivals

선택적으로 특정 노선만 요청할 수 있다.

GET /api/v1/stations/{station_id}/arrivals?route_ids=341,360

Response:

{
  "station": {
    "station_id": "123456",
    "name": "강남역"
  },
  "updated_at": "2026-08-12T09:27:00+09:00",
  "arrivals": [
    {
      "route_id": "341",
      "route_name": "341",
      "arrival_at": "2026-08-12T09:30:00+09:00",
      "remaining_seconds": 180,
      "remaining_stops": 2,
      "vehicle_status": "RUNNING"
    },
    {
      "route_id": "360",
      "route_name": "360",
      "arrival_at": "2026-08-12T09:34:00+09:00",
      "remaining_seconds": 420,
      "remaining_stops": 4,
      "vehicle_status": "RUNNING"
    }
  ]
}

중요

arrival_at이 primary display source다.

remaining_seconds는 편의상 제공하지만 iOS에서 countdown의 기준값으로 사용하지 않는다.

⸻

12. Arrival 데이터 모델

class BusArrival(BaseModel):
    route_id: str
    route_name: str
    arrival_at: datetime | None
    remaining_seconds: int | None
    remaining_stops: int | None
    vehicle_status: Literal[
        "RUNNING",
        "WAITING",
        "NOT_AVAILABLE",
        "UNKNOWN"
    ]

⸻

13. 서울시 API Client

서울시 API에 직접 접근하는 코드는 반드시 별도의 Client에 격리한다.

class SeoulBusClient:
    async def search_stations(
        self,
        keyword: str,
    ) -> list[Station]:
        ...
    async def get_station(
        self,
        station_id: str,
    ) -> Station:
        ...
    async def get_arrivals(
        self,
        station_id: str,
    ) -> list[BusArrival]:
        ...

Service 계층에서 서울시 API URL이나 인증키를 직접 다루지 않는다.

⸻

14. HTTP Client 요구사항

httpx.AsyncClient 사용.

요구사항:

* connect timeout
* read timeout
* total timeout
* 외부 API 4xx/5xx 처리
* JSON parsing error 처리
* connection error 처리
* 로그 기록

기본 timeout:

5 seconds

단, 실제 서울시 API 응답 특성에 따라 조정 가능.

⸻

15. Cache

MVP에서는 Redis를 optional로 구현한다.

Cache key:

station:{station_id}:arrivals

예:

station:123456:arrivals

TTL:

30 seconds

동작:

Request
   │
   ↓
Redis 확인
   │
   ├── HIT ─────→ Cached response
   │
   └── MISS
         │
         ↓
   Seoul Bus API
         │
         ↓
       Redis
         │
         ↓
      Response

Cache가 필요한 이유

같은 정류장을 여러 사용자가 동시에 조회하는 경우 서울시 API에 불필요한 요청을 반복하지 않기 위함이다.

⸻

16. Cache Stampede 방지

같은 정류장 cache가 만료된 순간:

User A ─┐
User B ─┤
User C ─┤
User D ─┤
         ↓
      Cache MISS

가 발생할 수 있다.

MVP에서는 단순 구현으로 시작한다.

Production에서는:

* Redis distributed lock
* single-flight
* short stale cache

중 하나를 적용한다.

⸻

17. Error Response

모든 API 오류 형식은 통일한다.

{
  "error": {
    "code": "SEOUL_BUS_API_UNAVAILABLE",
    "message": "버스 정보를 일시적으로 조회할 수 없습니다."
  }
}

예상 Error Code:

INVALID_REQUEST
STATION_NOT_FOUND
ROUTE_NOT_FOUND
SEOUL_BUS_API_ERROR
SEOUL_BUS_API_TIMEOUT
CACHE_ERROR
INTERNAL_SERVER_ERROR

외부 API의 상세 오류 내용이나 API Key는 사용자에게 노출하지 않는다.

⸻

18. iOS Application 구조

ios/
├── BusWidgetApp/
│   ├── App/
│   ├── Models/
│   ├── Services/
│   ├── Repositories/
│   ├── ViewModels/
│   ├── Views/
│   └── Storage/
│
├── BusWidgetExtension/
│   ├── BusWidget.swift
│   ├── BusWidgetProvider.swift
│   ├── BusWidgetEntry.swift
│   ├── Views/
│   └── Models/
│
└── Shared/
    ├── Models/
    └── Storage/

⸻

19. iOS 데이터 저장

App Group을 사용한다.

예:

group.com.example.buswidget

App과 Widget Extension이 동일한 데이터를 읽을 수 있도록 한다.

저장할 데이터:

{
  "stationId": "123456",
  "stationName": "강남역",
  "routeIds": [
    "341",
    "360"
  ]
}

MVP에서는 UserDefaults(suiteName:) 사용 가능.

데이터가 복잡해지면 SwiftData 또는 파일 기반 저장소로 변경한다.

⸻

20. 사용자 설정 Flow

앱 실행:

Home
  ↓
정류장 추가
  ↓
정류장 검색
  ↓
정류장 선택
  ↓
버스 노선 선택
  ↓
저장
  ↓
위젯 추가 안내

⸻

21. 정류장 검색 화면

SwiftUI:

┌──────────────────────────┐
│ 정류장 선택               │
│                          │
│ 🔍 강남역                 │
├──────────────────────────┤
│                          │
│ 강남역                   │
│ 역삼역 방면              │
│                          │
├──────────────────────────┤
│ 강남역                   │
│ 신분당선 방면            │
└──────────────────────────┘

사용자가 정류장을 선택하면 해당 정류장의 노선 목록을 조회한다.

⸻

22. 노선 선택 화면

┌──────────────────────────┐
│ 강남역                   │
│                          │
│ ☑ 341                    │
│ ☑ 360                    │
│ ☐ 740                    │
│ ☐ 146                    │
│                          │
│          저장            │
└──────────────────────────┘

MVP에서는 최대 4개 노선까지 선택.

⸻

23. Widget Configuration

Apple의 AppIntentConfiguration을 우선 사용한다.

Widget에서 사용자가 직접:

정류장 = 강남역

을 선택할 수 있도록 확장 가능하게 설계한다.

초기 MVP에서는 앱에서 설정한 값을 App Group을 통해 Widget이 읽는 방식으로 구현해도 된다.

⸻

24. Widget Family

MVP:

.systemSmall
.systemMedium

우선 지원.

Small

┌─────────────────────┐
│ 🚌 강남역            │
│                     │
│ 341      3분         │
│ 360      7분         │
└─────────────────────┘

Medium

┌──────────────────────────────┐
│ 🚌 강남역                    │
│                              │
│ 341   3분    360   7분       │
│ 740  15분                    │
│                              │
│ 업데이트 09:27               │
└──────────────────────────────┘

⸻

25. Widget Timeline 설계

WidgetKit은 위젯을 계속 실행하는 구조가 아니다.

Apple은 WidgetKit에 dynamic reload budget을 적용하며, 자주 보는 위젯의 일반적인 예시로 하루 4070회의 reload를 제시한다. 이는 대략 1560분 간격에 해당하지만 고정된 주기가 아니다. WidgetKit은 timeline의 지정 시각보다 늦게 업데이트할 수도 있다. (Apple Developer)

따라서 다음과 같이 설계한다.

잘못된 설계

매 1분마다 API 호출

금지.

올바른 설계

API 호출
    ↓
arrivalAt 확보
    ↓
TimelineEntry 저장
    ↓
Dynamic Date로 countdown 표시

⸻

26. Timeline Entry

예:

struct BusWidgetEntry: TimelineEntry {
    let date: Date
    let stationName: String
    let arrivals: [BusArrivalEntry]
    let updatedAt: Date
}

BusArrivalEntry:

struct BusArrivalEntry {
    let routeName: String
    let arrivalAt: Date?
    let remainingStops: Int?
}

⸻

27. Dynamic Countdown

Widget UI에서 단순 문자열:

Text("3분")

을 사용하지 않는다.

도착 예정 시간을 Date로 전달하고 SwiftUI의 dynamic date rendering을 사용한다.

개념적으로:

Text(arrivalAt, style: .relative)

또는 countdown/timer에 적합한 Date 스타일을 사용한다.

Apple은 WidgetKit에서 위젯이 계속 실행되지 않아도 dynamic date를 통해 countdown을 표시할 수 있도록 지원한다. (Apple Developer)

⸻

28. Timeline Refresh 정책

Timeline Provider가 서버에서 최신 데이터를 가져온 후 timeline을 생성한다.

예:

09:27 API 조회
341 → 09:30
360 → 09:34
740 → 09:42

Timeline Entry:

09:27
341 3분
360 7분
740 15분

이후 WidgetKit에게 적절한 refresh policy를 제공한다.

예:

Timeline(
    entries: [entry],
    policy: .after(nextRefreshDate)
)

단, after()는 정확히 해당 시각에 업데이트된다는 보장이 아니다.

Apple 공식 문서에서도 TimelineReloadPolicy는 WidgetKit이 새로운 timeline을 요청할 수 있는 가장 이른 시점을 지정하는 것이며, 실제 view update가 해당 시각보다 늦어질 수 있다고 설명한다. (Apple Developer)

⸻

29. Widget의 API 호출

Widget Extension에서 Backend API를 직접 호출할 수 있다.

Widget Provider
     │
     ↓
URLSession
     │
     ↓
FastAPI
     │
     ↓
Seoul API

Apple도 Widget에서 URLSession을 사용해 서버에서 데이터를 가져와 timeline을 생성하는 방식을 공식적으로 지원한다. (Apple Developer)

MVP에서는 이 방식을 사용한다.

⸻

30. Widget API 호출 실패

API 실패 시 기존 데이터를 최대한 유지한다.

예:

현재:
341 → 3분
360 → 7분

API 실패:

341 → 3분
360 → 7분
⚠ 업데이트 실패

기존 데이터가 없으면:

┌──────────────────────┐
│ 🚌 강남역             │
│                      │
│ 정보를 가져올 수      │
│ 없습니다              │
│                      │
│ 앱에서 다시 확인      │
└──────────────────────┘

⸻

31. 데이터 freshness

각 응답에 반드시:

"updated_at": "2026-08-12T09:27:00+09:00"

을 포함한다.

Widget에는:

업데이트 09:27

을 표시한다.

사용자가 실제 버스 데이터가 얼마나 오래된 것인지 판단할 수 있도록 한다.

⸻

32. Stale 데이터 처리

다음 기준을 사용한다.

0~60초
→ 정상
60~180초
→ 정상 + 작은 stale 표시 가능
180~300초
→ "업데이트 지연"
300초 이상
→ 도착정보를 신뢰하지 않고 "정보 갱신 필요"

단, 이 기준은 실제 서울시 API의 갱신 특성을 테스트한 후 조정한다.

⸻

33. 버스 상태

도착정보가 없는 경우:

341
정보 없음

버스 운행 종료:

341
운행 종료

첫차 전:

341
운행 전

막차 이후:

341
운행 종료

API가 정확한 상태를 제공하지 않는 경우에는:

정보 없음

으로 표시한다.

추측해서 운행 종료라고 판단하지 않는다.

⸻

34. Backend API 호출 최적화

Widget에서:

GET /api/v1/stations/123456/arrivals?route_ids=341,360

처럼 한 번의 요청으로 필요한 모든 노선을 조회한다.

다음 방식은 사용하지 않는다.

GET /341
GET /360
GET /740

⸻

35. Backend Cache 전략

기본:

TTL = 30초

단, 실제 API rate limit 및 데이터 freshness 테스트 후:

15~60초

범위에서 조정 가능.

사용자에게 반환하는 updated_at은 실제 외부 API 데이터를 가져온 시점 또는 데이터 자체의 제공 시각을 명확하게 구분한다.

필요하다면:

{
  "fetched_at": "...",
  "data_updated_at": "..."
}

로 분리한다.

⸻

36. 인증

MVP에서는 사용자 계정 기능을 구현하지 않는다.

Backend:

GET /api/v1/stations/search
GET /api/v1/stations/{id}
GET /api/v1/stations/{id}/arrivals

모두 공개 API로 제공한다.

단, Production에서는 최소한:

* Rate Limiting
* API abuse 방지
* CORS 제한
* HTTPS

를 적용한다.

서울시 API Key는 절대로 iOS 앱에 포함하지 않는다.

⸻

37. Rate Limiting

FastAPI 서버에 IP 기준 rate limit을 적용한다.

MVP:

60 requests / minute / IP

예외 및 실제 운영 환경에 맞춰 조정한다.

⸻

38. Logging

Backend 로그:

INFO
station_id=123456
action=get_arrivals
cache=hit

또는:

INFO
station_id=123456
action=get_arrivals
cache=miss
external_api=success
latency_ms=183

에러:

ERROR
station_id=123456
external_api=timeout

API Key는 절대 로그에 기록하지 않는다.

⸻

39. Observability

MVP:

* structured logging
* request latency
* external API latency
* cache hit/miss
* error count

Production:

* CloudWatch
* Sentry 선택
* OpenTelemetry 선택

⸻

40. 테스트 전략

Backend Unit Test

SeoulBusClient

테스트:

* 정상 응답
* timeout
* HTTP 500
* 잘못된 JSON
* 필수 필드 누락

ArrivalService

테스트:

* 정상 데이터 변환
* arrival_at 계산
* 노선 필터
* 데이터 없음
* 외부 API 오류

Cache

테스트:

* cache hit
* cache miss
* TTL
* stale data

⸻

41. Backend Integration Test

FastAPI TestClient 또는 async client를 사용한다.

테스트:

GET /health
GET /stations/search
GET /stations/{id}
GET /stations/{id}/arrivals

외부 서울시 API는 테스트에서 mock한다.

실제 서울시 API를 CI에서 호출하지 않는다.

⸻

42. iOS 테스트

App

* 정류장 검색
* 정류장 선택
* 노선 선택
* 설정 저장
* 설정 수정

Widget

* 정상 데이터
* 데이터 없음
* API 실패
* stale 데이터
* 도착 직전
* 이미 도착한 버스
* 여러 버스
* Small
* Medium

⸻

43. Countdown 테스트

반드시 다음 테스트를 수행한다.

arrivalAt = 현재 + 10분

예상:

10분

시간이 흐르면:

9분
8분
7분
...

도착 시:

도착

단, WidgetKit dynamic date의 실제 렌더링 동작은 실제 기기에서 확인한다.

⸻

44. Widget Reload 테스트

다음 사항을 반드시 실제 iPhone에서 테스트한다.

1. Widget 최초 추가
2. 홈 화면 이동
3. 앱 실행
4. 앱 종료
5. 장시간 대기
6. Wi-Fi → LTE 전환
7. 네트워크 끊김
8. 저전력 모드
9. 홈 화면에서 위젯을 자주 보는 경우
10. 위젯을 거의 보지 않는 경우

Xcode debugger에서는 WidgetKit의 실제 reload budget 동작이 그대로 재현되지 않을 수 있으므로 실제 기기에서 테스트한다. Apple 공식 문서에서도 WidgetKit의 refresh 제한이 Xcode debugger에서는 적용되지 않는다고 설명한다. (Apple Developer)

⸻

45. 앱과 Widget 데이터 공유

App Group:

group.com.example.buswidget

사용.

앱에서:

selectedStation
selectedRoutes

를 저장하면 Widget에서 동일 데이터를 읽는다.

설정 변경 시:

WidgetCenter.shared.reloadTimelines(
    ofKind: "BusArrivalWidget"
)

을 호출한다.

Apple은 앱 상태가 Widget의 timeline에 영향을 주는 경우 WidgetCenter를 이용해 특정 Widget의 timeline을 reload할 수 있도록 제공한다. (Apple Developer)

⸻

46. 사용자 설정 모델

struct WidgetConfigurationData: Codable {
    let stationId: String
    let stationName: String
    let routeIds: [String]
}

MVP:

stationId: 1개
routeIds: 최대 4개

⸻

47. Backend Response Contract

iOS는 서울시 API response를 절대 직접 파싱하지 않는다.

반드시:

Seoul API
    ↓
FastAPI Client
    ↓
Pydantic Schema
    ↓
Normalized API Response
    ↓
iOS

구조를 유지한다.

이렇게 해야 서울시 API 변경이 iOS 코드에 직접 영향을 주지 않는다.

⸻

48. API Versioning

모든 Backend API는:

/api/v1/

을 사용한다.

예:

/api/v1/stations/search
/api/v1/stations/{station_id}
/api/v1/stations/{station_id}/arrivals

향후 breaking change 발생 시:

/api/v2/

를 추가한다.

⸻

49. 보안 요구사항

반드시 지킬 것.

Git에 저장 금지

SEOUL_BUS_API_KEY
AWS credentials
Redis password

저장 위치

Local:

.env

Production:

AWS Secrets Manager

HTTPS

Production에서는 HTTPS만 허용.

⸻

50. Docker

Backend Dockerfile 요구사항:

* Python 3.12+
* uv 사용
* multi-stage build 권장
* non-root user
* healthcheck

예상 실행:

docker compose up -d

구성:

backend
redis

⸻

51. Local Development

┌─────────────────────┐
│ Mac                 │
│                     │
│ FastAPI             │
│ localhost:8000      │
│                     │
│ Redis               │
│ localhost:6379      │
└──────────┬──────────┘
           │
           ↓
       iPhone

iPhone 실기기에서 로컬 FastAPI를 호출할 경우 Mac과 iPhone이 같은 Wi-Fi에 있어야 하며 localhost가 아닌 Mac의 LAN IP를 사용해야 한다.

예:

http://192.168.x.x:8000

단, Production에서는 반드시 HTTPS를 사용한다.

⸻

52. Production Architecture

MVP 이후:

                  Internet
                     │
                     ↓
              CloudFront / ALB
                     │
                     ↓
                FastAPI
                     │
          ┌──────────┴──────────┐
          ↓                     ↓
       Redis              Seoul Bus API

AWS 선택지는:

ECS Fargate
+
ElastiCache Redis
+
ALB

를 우선 고려한다.

단순 MVP라면:

Lambda
+
API Gateway

도 가능하다.

⸻

53. AWS 비용 최적화

초기 사용자가 적다면 Redis를 바로 도입하지 않아도 된다.

Phase 1:

FastAPI
   ↓
서울시 API

Phase 2:

FastAPI
   ↓
Redis
   ↓
서울시 API

Phase 3:

ALB
 ↓
FastAPI x N
 ↓
Redis
 ↓
서울시 API

순으로 확장한다.

⸻

54. 개발 Phase

Phase 1 — Backend

목표:

서울시 API
      ↓
FastAPI
      ↓
JSON

구현:

* 프로젝트 초기화
* 환경변수
* SeoulBusClient
* Station API
* Arrival API
* Pydantic schema
* Error handling
* Unit test

완료 조건:

pytest

전체 통과.

⸻

55. Phase 2 — iOS App

구현:

* SwiftUI 프로젝트
* Networking
* Station search
* Station selection
* Route selection
* App Group
* Local configuration

완료 조건:

정류장 검색
→ 선택
→ 노선 선택
→ 저장

정상 동작.

⸻

56. Phase 3 — Widget

구현:

* Widget Extension
* TimelineProvider / AppIntentTimelineProvider
* Widget Entry
* API networking
* Dynamic Date
* Small
* Medium
* Error state
* stale state

완료 조건:

실제 iPhone 홈 화면에서:

341   3분
360   7분

등을 표시할 수 있어야 한다.

⸻

57. Phase 4 — Refresh 최적화

목표:

API 호출 횟수 최소화
+
사용자에게 최신 정보 제공

구현:

* Timeline policy
* Widget reload
* App foreground reload
* Cache
* stale data 처리

중요:

1분마다 Widget reload를 요구하지 않는다.

WidgetKit이 허용하는 reload budget을 고려한다. Apple은 timeline entry를 약 5분보다 짧은 간격으로 만드는 것을 권장하지 않으며, 실제 reload 시점도 시스템이 조정할 수 있다. (Apple Developer)

⸻

58. Phase 5 — Redis

필요할 경우 추가.

GET /arrivals
        ↓
Redis
        │
     ┌──┴──┐
    HIT   MISS
     │      │
     │      ↓
     │   Seoul API
     │      │
     └──────┘

TTL:

30 seconds

부터 시작.

⸻

59. Phase 6 — Production

구현:

* HTTPS
* AWS deployment
* Secret Manager
* Rate limiting
* Monitoring
* Error tracking
* CI/CD
* Health check
* Docker image build

⸻

60. CI/CD

GitHub Actions:

Push
 ↓
Lint
 ↓
Test
 ↓
Build
 ↓
Docker Build
 ↓
Deploy

Backend:

ruff
pytest
docker build

iOS:

swift test
xcodebuild

필요 시 TestFlight 배포 단계 추가.

⸻

61. Definition of Done

Backend

* FastAPI 실행
* /health
* 정류장 검색
* 정류장 상세
* 버스 도착정보
* Pydantic validation
* 서울시 API client 분리
* timeout 처리
* 오류 처리
* unit test
* integration test
* API Key 환경변수화
* Docker 실행 가능

iOS

* SwiftUI 앱 실행
* 정류장 검색
* 정류장 선택
* 노선 선택
* 설정 저장
* App Group
* Backend API 연결
* 네트워크 오류 처리

Widget

* Widget Extension
* Small
* Medium
* Timeline
* Backend API 호출
* arrivalAt 기반 countdown
* 업데이트 시각 표시
* API 오류 상태
* stale 상태
* 실제 iPhone 테스트

⸻

62. 절대 하지 말아야 할 것

1.

Widget → 매 1분 API 호출

하지 않는다.

2.

Widget → 서울시 API 직접 호출

을 Production 구조로 사용하지 않는다.

서울시 API Key 보호를 위해 Backend를 거친다.

3.

"3분"

이라는 문자열을 저장하지 않는다.

대신:

arrivalAt = Date

를 저장한다.

4.

서울시 API response schema를 iOS가 직접 의존하지 않는다.

5.

WidgetKit이 정확히 5분마다 실행된다고 가정하지 않는다.

6.

Widget의 countdown과 서버 데이터 갱신을 하나의 문제로 취급하지 않는다.

⸻

63. Agent에게 구현시키는 순서

Coding Agent에게는 다음 순서로 작업시킨다.

Task 1
Backend project initialization
↓
Task 2
Seoul Bus API client
↓
Task 3
Station APIs
↓
Task 4
Arrival API
↓
Task 5
Backend tests
↓
Task 6
SwiftUI project
↓
Task 7
Backend networking
↓
Task 8
Station search UI
↓
Task 9
Route selection UI
↓
Task 10
App Group storage
↓
Task 11
Widget Extension
↓
Task 12
TimelineProvider
↓
Task 13
Dynamic countdown
↓
Task 14
Widget error/stale state
↓
Task 15
Widget refresh optimization
↓
Task 16
Redis cache
↓
Task 17
Docker
↓
Task 18
CI/CD
↓
Task 19
Production deployment

각 Task는 이전 Task의 테스트가 통과한 경우에만 다음 단계로 진행한다.

⸻

64. Agent의 최종 목표

최종적으로 다음 UX를 만족해야 한다.

사용자가 앱에서:

강남역 검색
 ↓
정류장 선택
 ↓
341 / 360 선택

하면 홈 화면 Widget에:

┌──────────────────────────┐
│ 🚌 강남역                 │
│                          │
│ 341       3분             │
│ 360       7분             │
│                          │
│ 업데이트 09:27            │
└──────────────────────────┘

이 표시되어야 한다.

그리고 시간이 흐르면 별도의 매분 API 호출 없이:

3분
 ↓
2분
 ↓
1분
 ↓
도착

으로 표시된다.

새로운 실시간 버스 정보가 필요해지는 시점에는 WidgetKit의 timeline/reload 정책에 따라 Backend에서 최신 정보를 가져온다.

WidgetKit은 시스템이 reload를 동적으로 관리하므로 정확한 갱신 시각을 보장하지 않는다. 따라서 UI에는 반드시 updatedAt을 표시하고, 오래된 데이터는 stale 상태로 구분한다. (Apple Developer)

⸻

65. Agent 구현 시 우선순위

P0 — 반드시 구현

서울시 API
FastAPI
정류장 검색
도착정보
SwiftUI
WidgetKit
App Group
arrivalAt
Dynamic countdown

P1 — 중요

Redis
Cache
Error handling
Stale state
Rate limiting
Docker
Tests

P2 — 이후

AWS
CI/CD
Monitoring
TestFlight
Widget AppIntent configuration
Widget push notifications
Live Activity

P2 기능은 MVP에 포함하지 않는다.

⸻

66. MVP의 성공 기준

다음 시나리오가 실제 iPhone에서 성공하면 MVP 완료다.

1. 앱 실행
2. "강남역" 검색
3. 정류장 선택
4. 341번 선택
5. 저장
6. 홈 화면에 Widget 추가
7. Widget에서 341번 도착정보 확인
8. 시간이 지나면서 countdown 감소
9. 앱을 열지 않고 Widget만 확인
10. 새로운 API 데이터가 Widget에 반영
11. API 실패 시 적절한 오류 상태 표시
12. 오래된 데이터는 stale 상태 표시

이 12개가 모두 실제 기기에서 동작하는 것을 MVP의 Definition of Done으로 한다.
