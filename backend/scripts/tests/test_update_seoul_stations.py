"""CSV validation and transaction tests for Seoul station enrichment."""

from __future__ import annotations

import csv
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "update_seoul_stations.py"
SPEC = importlib.util.spec_from_file_location("update_seoul_stations", SCRIPT)
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


def csv_row(node="SEB100000001", ars="1234", name="서울역"):
    return [node, name, "37.55", "126.97", "2025-10-31", ars, "11", "서울특별시", "서울BIS"]


class CSVTests(unittest.TestCase):
    def read_rows(self, rows, encoding="cp949"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stations.csv"
            with path.open("w", encoding=encoding, newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(updater.HEADERS)
                writer.writerows(rows)
            return updater.read_stations(path)

    def test_encoding_leading_zero_and_provider_selection(self):
        other_provider = csv_row("GGB100000001")
        other_provider[-1] = "경기BIS"
        rows = [csv_row(), other_provider, csv_row("SEB200000001"), csv_row("SEB100000002", "0")]
        for encoding in ("cp949", "utf-8-sig"):
            with self.subTest(encoding=encoding):
                stations, stats = self.read_rows(rows, encoding)
                self.assertEqual(len(stations), 1)
                self.assertEqual(stations[0]["station_id"], "01234")
                self.assertEqual(stations[0]["node_id"], "100000001")
                self.assertEqual(stats["total_rows"], 4)
                self.assertEqual(stats["excluded_other_provider_or_city"], 1)
                self.assertEqual(stats["excluded_unconfirmed_gyeonggi_node"], 1)
                self.assertEqual(stats["excluded_missing_ars"], 1)

    def test_rejects_duplicates_invalid_coordinates_and_empty_selection(self):
        invalid_coordinate = csv_row()
        invalid_coordinate[2] = "NaN"
        for rows in (
            [csv_row(), csv_row("SEB100000002", "01234")],
            [csv_row(), csv_row("SEB100000001", "5678")],
            [invalid_coordinate],
            [csv_row("SEB200000001")],
            [csv_row(ars="123456")],
            [csv_row()[:-1]],
        ):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.read_rows(rows)

    def test_gyeonggi_uses_seoul_ars_and_excludes_ambiguous_ids(self):
        gyeonggi = csv_row("GGB200000001", "99999")
        gyeonggi[6:] = ["31020", "경기도 성남시", "경기BIS"]
        rows = [
            csv_row(),
            csv_row("SEB200000001", "1235"),
            gyeonggi,
            csv_row("SEB100000002", "5678"),
            csv_row("SEB100000003", "05678"),
        ]
        stations, stats = self.read_rows(rows)
        self.assertEqual([station["station_id"] for station in stations], ["01234", "01235"])
        self.assertEqual(stats["eligible_gyeonggi"], 1)
        self.assertEqual(stats["excluded_ambiguous_id_rows"], 2)


class ConnectionConfigTests(unittest.TestCase):
    def test_explicit_environment_selection(self):
        with patch.dict(os.environ, {"STATION_TEST_URL": " postgresql://localhost/stations "}, clear=True):
            self.assertEqual(updater.database_url_from_env("STATION_TEST_URL"), "postgresql://localhost/stations")
            with self.assertRaises(ValueError):
                updater.database_url_from_env("DATABASE_URL")

    def test_invalid_url_does_not_expose_secret(self):
        with self.assertRaises(ValueError) as caught:
            updater.run_direct_database("SELECT 1", "invalid://user:private-password@db")
        self.assertNotIn("private-password", str(caught.exception))


@unittest.skipUnless(os.environ.get("TEST_STATION_CONTAINER"), "requires isolated PostgreSQL container")
class DatabaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ["TEST_STATION_CONTAINER"].startswith("bus-alarm-station-test-"):
            raise RuntimeError("Use a disposable bus-alarm-station-test-* container only")

    def sql(self, query):
        command = [
            "docker",
            "exec",
            "-i",
            os.environ["TEST_STATION_CONTAINER"],
            "psql",
            "-X",
            "-qAt",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "buswidget",
            "-d",
            "buswidget",
        ]
        return subprocess.run(command, input=query, text=True, capture_output=True, check=True).stdout.strip()

    def setUp(self):
        # This suite owns the entire DB in TEST_STATION_CONTAINER, never the app DB.
        self.sql("""
DROP TABLE IF EXISTS route_stops, routes, stations CASCADE;
CREATE TABLE stations (station_id varchar(5) PRIMARY KEY,node_id varchar(9) NOT NULL,
 name varchar(128) NOT NULL,latitude double precision NOT NULL,longitude double precision NOT NULL);
CREATE TABLE routes (route_id varchar(9) PRIMARY KEY,name varchar(128));
CREATE TABLE route_stops (route_id varchar(9) REFERENCES routes(route_id),
 station_id varchar(5) REFERENCES stations(station_id),sequence integer);
INSERT INTO stations VALUES
 ('01234','100000001','old name',37.5,127),
 ('01235','100000002','not in CSV',37.5,127),
 ('01236','100000003','ARS conflict',37.5,127),
 ('01237','100000004','node conflict',37.5,127);
INSERT INTO routes VALUES ('100000001','100');
INSERT INTO route_stops VALUES ('100000001','01234',1);
""")
        self.stations = [
            dict(station_id="01234", node_id="100000001", name="서울 '역' \\ 출구", latitude=37.55, longitude=126.97),
            dict(station_id="01238", node_id="100000008", name="새 정류장", latitude=37.55, longitude=126.97),
            dict(station_id="01236", node_id="100000009", name="충돌", latitude=37.55, longitude=126.97),
            dict(station_id="01239", node_id="100000004", name="충돌", latitude=37.55, longitude=126.97),
        ]

    def snapshot(self):
        return self.sql("SELECT row_to_json(s) FROM stations s ORDER BY station_id;")

    def run_update(self, apply):
        return updater.run_database(updater.build_sql(self.stations, apply), os.environ["TEST_STATION_CONTAINER"])

    def test_dry_run_apply_repeat_preserve_routes_and_conflicts(self):
        before = self.snapshot()
        report = self.run_update(False)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((report["insert"], report["update"], report["conflict_skipped"]), (1, 1, 2))
        applied = self.run_update(True)
        self.assertEqual(applied["mode"], "applied")
        self.assertEqual(self.sql("SELECT count(*) FROM stations;"), "5")
        self.assertEqual(self.sql("SELECT name FROM stations WHERE station_id='01234';"), self.stations[0]["name"])
        self.assertEqual(self.sql("SELECT name FROM stations WHERE station_id='01236';"), "ARS conflict")
        self.assertEqual(self.sql("SELECT count(*) FROM routes;"), "1")
        self.assertEqual(self.sql("SELECT count(*) FROM route_stops WHERE station_id='01234';"), "1")
        second = self.run_update(True)
        self.assertEqual((second["insert"], second["update"], second["unchanged"]), (0, 0, 2))

    def test_database_error_rolls_back_all_updates(self):
        self.sql("ALTER TABLE stations ADD CHECK (name <> '새 정류장');")
        before = self.snapshot()
        with self.assertRaises(RuntimeError):
            self.run_update(True)
        self.assertEqual(self.snapshot(), before)


class DirectDatabaseTests(DatabaseTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        address = subprocess.check_output(
            ["docker", "port", os.environ["TEST_STATION_CONTAINER"], "5432/tcp"], text=True
        ).strip()
        if not address.startswith("127.0.0.1:") or "\n" in address:
            raise RuntimeError("Test PostgreSQL must have one port bound to 127.0.0.1")
        cls.database_url = f"postgresql+asyncpg://buswidget:buswidget@{address}/buswidget"

    def run_update(self, apply):
        return updater.run_database(updater.build_sql(self.stations, apply), None, self.database_url)


if __name__ == "__main__":
    unittest.main()
