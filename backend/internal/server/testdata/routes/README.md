# 노선 선택 테스트 데이터

`gg-info.xml`과 `gg-stops.xml`은 공식 XML 필드로 구성한 **합성 fixture**다. 9304 / 05267 식별 예시를 사용하지만 정류장 순서, 회차점, 방향, 좌표, 차량은 실제 운행 검증 자료가 아니다. 실제 운영 활성화 전 `make routes-check`와 실제 지도/승강장 확인이 필요하다.

- 경기: busrouteservice/v2 getBusRouteInfoItemv2, getBusRouteStationListv2
- 경기 방향별 도착: busarrivalservice/v2 getBusArrivalItemv2 (stationId, routeId, staOrder)
- 서울 방향별 도착: arrive/getArrInfoByRouteAll에서 stId + staOrd로 정확한 항목 선택

`verified-9304-info.xml`과 `verified-9304-stops.xml`은 2026-09-17 승인 후 실제 공개 응답에서 필요한 정류장·노선 필드만 추린 회귀 자료다. 정류장 목록은 JSON 응답을 동일 필드의 XML로 정규화했다. 50개 경유점 중 순번 25가 강변역 node 104000069이며, 노선 응답의 누락된 mobileNo는 정류소 항목 조회 결과 05267로 보완한다. 공식 명세: https://www.gbis.go.kr/gbis2014/publicService.action?cmd=mBusRouteStation
