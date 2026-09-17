"""Read-only route-map smoke check. No credentials, DB writes or push registration."""

import argparse
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = Request(base.rstrip("/") + path, data=data, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    args = parser.parse_args()
    base = args.base_url
    try:
        capabilities = request(base, "/api/v2/capabilities")
        nearby = request(base, "/api/v2/stations/nearby?south=37.53&west=127.09&north=37.54&east=127.10")
        if not isinstance(nearby.get("stations"), list) or not isinstance(nearby.get("truncated"), bool):
            raise ValueError("지도 정류장 응답을 확인하지 못했습니다.")
        result = request(base, "/api/v2/routes/search?q=9304")
        route = next(r for r in result["routes"] if r["route_ref"].startswith("gg:") and r["name"].startswith("9304"))
        detail = request(base, "/api/v2/routes/" + route["route_ref"])
        stops = [
            s
            for s in detail["stops"]
            if s["station"]["display_number"] == "05267" and s["station_ref"].endswith(":104000069") and s["selectable"]
        ]
        if not stops:
            raise ValueError("9304 / 05267의 방향을 확인하지 못했습니다.")
        fields = [
            "boarding_id",
            "route_ref",
            "route_revision",
            "route_name",
            "station_ref",
            "sequence",
            "direction_id",
            "direction",
        ]
        for stop in stops:
            body = {"station_ref": stop["station_ref"], "selections": [{key: stop[key] for key in fields}]}
            request(base, "/api/v2/selections/validate", body)
            request(base, "/api/v2/arrivals", body)
        print(
            json.dumps(
                {
                    "success": True,
                    "discovery_enabled": capabilities["route_map"],
                    "map_station_count": len(nearby["stations"]),
                    "verified_boardings": len(stops),
                },
                ensure_ascii=False,
            )
        )
        return 0
    except (HTTPError, URLError, ValueError, KeyError, StopIteration, TimeoutError) as error:
        # Do not echo full URLs, network exception strings or response bodies.
        print(
            json.dumps(
                {
                    "success": False,
                    "error_type": type(error).__name__,
                    "http_status": getattr(error, "code", None),
                    "message": "서버 연결·노선 API 승인·9304/05267 방향 데이터를 확인하세요.",
                },
                ensure_ascii=False,
            )
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
