"""Run native route selection UI tests against an isolated synthetic API."""

import argparse
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

STATION = {
    "station_ref": "gg:104000069",
    "name": "테크노마트앞.강변역 D",
    "display_number": "05267",
    "latitude": 37.535,
    "longitude": 127.094,
}
ROUTE = {
    "route_ref": "gg:227000040",
    "name": "9304",
    "region": "경기 · 하남",
    "kind": "직행좌석",
    "start": "강변역",
    "end": "하남",
}
SELECTION = {
    "boarding_id": "gg:227000040:104000069:1",
    "route_ref": ROUTE["route_ref"],
    "route_revision": "ui-fixture",
    "route_name": "9304",
    "station_ref": STATION["station_ref"],
    "sequence": 1,
    "direction_id": "outbound",
    "direction": "하남 방면",
}
STOP = {**SELECTION, "station": STATION, "next_stop": "다음 정류장 (테스트)", "selectable": True}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        print("UI fixture:", self.command, self.path, flush=True)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.endswith("/capabilities"):
            body = {"route_map": True}
        elif path.endswith("/routes/search"):
            body = {"routes": [ROUTE], "providers": [{"provider": "gg", "available": True}]}
        elif path.endswith("/geometry"):
            body = {"coordinates": [], "source": "stops"}
        elif path.endswith("/boarding-options"):
            body = {"station": STATION, "options": [STOP], "complete": True, "warnings": []}
        elif path.endswith("/routes/gg:227000040"):
            body = {
                "route": ROUTE,
                "revision": "ui-fixture",
                "directions": [{"id": "outbound", "name": "하남 방면"}],
                "stops": [STOP],
            }
        else:
            self.send_error(404)
            return
        self.send(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path.split("?")[0] == "/api/v2/selections/validate":
            self.send({"station": STATION, "selections": body["selections"]})
        else:
            self.send_error(404)

    def send(self, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", default="iPhone 17 Pro")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    server = ThreadingHTTPServer(("127.0.0.1", 8767), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run(["xcodegen", "generate"], cwd=root / "ios", check=True)
        env = {**os.environ, "ROUTE_UI_API_URL": f"http://127.0.0.1:{server.server_port}"}
        result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                "ios/BusWidget.xcodeproj",
                "-scheme",
                "RouteMapUI",
                "-destination",
                f"platform=iOS Simulator,name={args.simulator}",
                "CODE_SIGNING_ALLOWED=NO",
                "test",
            ],
            cwd=root,
            env=env,
        )
        return result.returncode
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    raise SystemExit(main())
