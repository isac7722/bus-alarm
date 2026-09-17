#!/usr/bin/env python3
"""Supplement Seoul and Seoul BIS Gyeonggi stops from a TAGO CSV snapshot."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
import uuid
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CSV = ROOT / "national_bus_station_data_20251031.csv"
HEADERS = [
    "정류장번호",
    "정류장명",
    "위도",
    "경도",
    "정보수집일",
    "모바일단축번호",
    "도시코드",
    "도시명",
    "관리도시명",
]


def read_stations(path: Path) -> tuple[list[dict], dict]:
    """Validate all input before selecting unambiguous Seoul station IDs."""
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8-sig")
        encoding = "utf-8-sig"
    except UnicodeDecodeError:
        text = raw.decode("cp949")
        encoding = "cp949"
    reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
    if reader.fieldnames != HEADERS:
        raise ValueError("CSV 컬럼이 국토교통부 전국 버스정류장 위치정보 형식과 다릅니다.")

    rows = []
    for row in reader:
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"CSV {reader.line_num}행: 컬럼 수가 다릅니다.")
        rows.append((reader.line_num, {key: value.strip() for key, value in row.items()}))
    # Seoul BIS labels even out-of-city stops as city 11. Confirm their actual
    # region by joining the numeric node ID to the Gyeonggi BIS rows, never ARS.
    node_cities = {}
    for _, row in rows:
        match = re.fullmatch(r"GGB([0-9]{9})", row["정류장번호"])
        if row["관리도시명"] == "경기BIS" and match:
            node_cities.setdefault(match.group(1), set()).add(row["도시코드"])
    gyeonggi_nodes = {
        node
        for node, cities in node_cities.items()
        if len(cities) == 1 and re.fullmatch(r"31[0-9]{3}", next(iter(cities)))
    }
    counts = Counter(total_rows=len(rows))
    dates = Counter()
    stations = []
    for line_number, row in rows:
        if row["도시코드"] != "11" or row["관리도시명"] != "서울BIS":
            counts["excluded_other_provider_or_city"] += 1
            continue
        match = re.fullmatch(r"SEB([12][0-9]{8})", row["정류장번호"])
        if not match:
            counts["excluded_unsupported_node"] += 1
            continue
        node_id = match.group(1)
        if node_id.startswith("2") and node_id not in gyeonggi_nodes:
            counts["excluded_unconfirmed_gyeonggi_node"] += 1
            continue
        mobile = row["모바일단축번호"]
        if mobile in ("", "0", "00000"):
            counts["excluded_missing_ars"] += 1
            continue
        if not re.fullmatch(r"[0-9]{1,5}", mobile) or int(mobile) == 0:
            raise ValueError(f"CSV {line_number}행: 잘못된 서울 ARS 번호입니다.")
        station_id = mobile.zfill(5)
        name = row["정류장명"]
        if not name or len(name) > 128 or "\x00" in name:
            raise ValueError(f"CSV {line_number}행: 잘못된 정류장 이름입니다.")
        latitude = float(row["위도"])
        longitude = float(row["경도"])
        if not (32 <= latitude <= 40 and 123 <= longitude <= 133):
            raise ValueError(f"CSV {line_number}행: 위경도 범위가 잘못되었습니다.")
        stations.append(
            {
                "station_id": station_id,
                "node_id": node_id,
                "name": name,
                "latitude": latitude,
                "longitude": longitude,
                "collected_on": row["정보수집일"],
            }
        )
    ars_counts = Counter(station["station_id"] for station in stations)
    node_counts = Counter(station["node_id"] for station in stations)
    ambiguous = [
        station for station in stations if ars_counts[station["station_id"]] > 1 or node_counts[station["node_id"]] > 1
    ]
    stations = [
        station
        for station in stations
        if ars_counts[station["station_id"]] == 1 and node_counts[station["node_id"]] == 1
    ]
    counts["excluded_ambiguous_id_rows"] = len(ambiguous)
    for station in stations:
        dates[station.pop("collected_on")] += 1
    if not stations:
        raise ValueError("반영 가능한 서울 정류장이 없습니다.")
    return stations, {
        "file": str(path),
        "encoding": encoding,
        **counts,
        "eligible_stations": len(stations),
        "eligible_seoul": sum(station["node_id"].startswith("1") for station in stations),
        "eligible_gyeonggi": sum(station["node_id"].startswith("2") for station in stations),
        "collection_dates": dict(dates),
        "ambiguous_id_sample": ambiguous[:20],
    }


def build_sql(stations: list[dict], apply: bool) -> str:
    """Plan and optionally upsert stations atomically, preserving all routes."""
    payload = json.dumps(stations, ensure_ascii=False, allow_nan=False)
    delimiter = f"$csv_{uuid.uuid4().hex}$"
    while delimiter in payload:
        delimiter = f"$csv_{uuid.uuid4().hex}$"
    lock = "LOCK TABLE stations IN SHARE ROW EXCLUSIVE MODE;" if apply else ""
    mutation = (
        """
UPDATE stations s SET name=p.name, latitude=p.latitude, longitude=p.longitude
FROM station_update_plan p
WHERE p.action='update' AND s.station_id=p.station_id AND s.node_id=p.node_id;
INSERT INTO stations (station_id,node_id,name,latitude,longitude)
SELECT station_id,node_id,name,latitude,longitude
FROM station_update_plan WHERE action='insert';
"""
        if apply
        else ""
    )
    mode = "applied" if apply else "dry_run"
    finish = "COMMIT" if apply else "ROLLBACK"
    return f"""
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
{lock}
CREATE TEMP TABLE station_update_source ON COMMIT DROP AS
SELECT * FROM json_to_recordset({delimiter}{payload}{delimiter}::json)
AS t(station_id varchar(5),node_id varchar(9),name varchar(128),
     latitude double precision,longitude double precision);
CREATE TEMP TABLE station_update_plan ON COMMIT DROP AS
SELECT incoming.*, CASE
  WHEN (existing.station_id IS NOT NULL AND existing.node_id <> incoming.node_id)
    OR EXISTS (SELECT 1 FROM stations other
               WHERE other.node_id=incoming.node_id
                 AND other.station_id<>incoming.station_id) THEN 'conflict'
  WHEN existing.station_id IS NULL THEN 'insert'
  WHEN (existing.name,existing.latitude,existing.longitude)
    IS DISTINCT FROM (incoming.name,incoming.latitude,incoming.longitude) THEN 'update'
  ELSE 'unchanged' END AS action
FROM station_update_source incoming
LEFT JOIN stations existing USING (station_id);
{mutation}
SELECT json_build_object(
  'mode','{mode}',
  'insert',count(*) FILTER (WHERE action='insert'),
  'update',count(*) FILTER (WHERE action='update'),
  'unchanged',count(*) FILTER (WHERE action='unchanged'),
  'conflict_skipped',count(*) FILTER (WHERE action='conflict'),
  'existing_stations_absent_from_csv',
    (SELECT count(*) FROM stations s WHERE NOT EXISTS
      (SELECT 1 FROM station_update_source i WHERE i.station_id=s.station_id)),
  'conflict_sample',coalesce((SELECT json_agg(c) FROM
    (SELECT station_id,node_id,name FROM station_update_plan
     WHERE action='conflict' ORDER BY station_id LIMIT 20) c),'[]'::json)
) FROM station_update_plan;
{finish};
"""


def run_direct_database(sql: str, database_url: str) -> dict:
    """Execute the same transaction using bundled libpq without Docker or psql."""
    try:
        import psycopg
    except ImportError:
        raise RuntimeError("PostgreSQL 드라이버가 없습니다. uv sync 후 uv run으로 실행하세요.") from None

    database_url = database_url.replace("postgresql+asyncpg://", "postgresql://", 1)
    if not database_url.startswith(("postgresql://", "postgres://")):
        raise ValueError("DB 주소는 postgresql://, postgres:// 또는 postgresql+asyncpg:// 형식이어야 합니다.")
    report = None
    try:
        # build_sql owns BEGIN/COMMIT/ROLLBACK. ClientCursor sends its batch
        # through the simple query protocol, matching psql's transaction scope.
        with psycopg.connect(
            database_url, autocommit=True, connect_timeout=10, cursor_factory=psycopg.ClientCursor
        ) as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql)
                while True:
                    if cursor.description:
                        report = cursor.fetchone()[0]
                    if not cursor.nextset():
                        break
    except psycopg.Error as error:
        # libpq errors can contain connection credentials or server addresses.
        code = error.sqlstate or "connection_error"
        raise RuntimeError(
            f"PostgreSQL 연결 또는 SQL 실행 실패 ({code}). DB 접속 설정과 스키마를 확인하세요."
        ) from None
    if not isinstance(report, dict):
        raise RuntimeError("DB에서 반영 결과를 반환하지 않았습니다.")
    return report


def database_url_from_env(name: str) -> str:
    """Require an explicitly selected environment variable; never fall back."""
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"환경변수 {name}이 비어 있습니다. 환경변수 또는 uv run --env-file로 설정하세요.")
    return value


def run_database(sql: str, container: str | None, database_url: str | None = None) -> dict:
    """Connect directly when selected, otherwise preserve the local Docker path."""
    if database_url is not None:
        if container:
            raise ValueError("DB 직접 연결과 --container를 동시에 지정할 수 없습니다.")
        return run_direct_database(sql, database_url)
    if container:
        command = ["docker", "exec", "-i", container]
    else:
        command = ["docker", "compose", "exec", "-T", "postgres"]
    command += [
        "psql",
        "-X",
        "-q",
        "-A",
        "-t",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        "buswidget",
        "-d",
        "buswidget",
    ]
    result = subprocess.run(
        command,
        input=sql,
        text=True,
        capture_output=True,
        cwd=ROOT,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"DB 작업 실패 (변경 트랜잭션 롤백):\n{result.stderr.strip()}")
    return json.loads(result.stdout)


def main() -> int:
    """Report the source and DB changes; write only with an explicit --apply."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV, help="TAGO CSV 경로 (UTF-8 또는 CP949)")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--container", help="다른 로컬 PostgreSQL 컨테이너 이름 (기본: compose postgres)")
    target.add_argument("--database-url-env", metavar="NAME", help="DB 주소를 담은 환경변수 이름 (예: DATABASE_URL)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="정류장 추가·수정 내용을 DB에 반영")
    mode.add_argument("--validate-only", action="store_true", help="DB 연결 없이 CSV만 검증")
    args = parser.parse_args()
    try:
        stations, source = read_stations(args.csv)
        report = {"source": source}
        if not args.validate_only:
            database_url = database_url_from_env(args.database_url_env) if args.database_url_env else None
            report["database"] = run_database(build_sql(stations, args.apply), args.container, database_url)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, UnicodeError, csv.Error, ValueError, RuntimeError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
