"""Offline tests for release ordering, version safety and Apple state handling."""

from __future__ import annotations

import importlib.util
import io
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "testflight.py"
spec = importlib.util.spec_from_file_location("testflight", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class TestProjectConfiguration(unittest.TestCase):
    def test_app_and_widget_plists_expand_build_version(self):
        for bundle in ("BusWidgetApp", "BusWidgetExtension"):
            with (module.IOS / bundle / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
            self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")


class TestVersions(unittest.TestCase):
    def test_numeric_versions_and_builds(self):
        self.assertEqual(module.next_versions(("1.0.0", "1"), ["1.0.9", "1.0.10"], ["9", "10"], []), ("1.0.11", "11"))

    def test_first_release(self):
        self.assertEqual(module.next_versions(("1.0.0", "1"), [], [], []), ("1.0.1", "2"))

    def test_attempted_upload_is_never_reused(self):
        reserved = [{"version": "1.0.2", "build": "3"}]
        self.assertEqual(module.next_versions(("1.0.0", "1"), ["1.0.1"], ["2"], reserved), ("1.0.3", "4"))

    def test_two_component_and_dotted_historical_build(self):
        self.assertEqual(module.next_versions(("2.0", "1"), ["1.9.8"], ["3.8.2"], []), ("2.0.1", "4"))

    def test_invalid_version_fails(self):
        with self.assertRaises(module.ReleaseError):
            module.version_tuple("1.0.beta")
        with self.assertRaises(module.ReleaseError):
            module.next_versions(("1.0.0", "9999"), [], [], [])


class TestAPI(unittest.TestCase):
    def setUp(self):
        self.api = module.AppStoreConnect(module.Credentials("id", "issuer", Path("/tmp/key.p8")))

    def test_pagination(self):
        self.api.get = MagicMock(
            side_effect=[
                {"data": [{"id": "1"}], "links": {"next": module.ASC_URL + "/v1/builds?cursor=2"}},
                {"data": [{"id": "2"}], "links": {"next": None}},
            ]
        )
        self.assertEqual([v["id"] for v in self.api.collection("/v1/builds", {})], ["1", "2"])

    def test_external_pagination_rejected_before_authentication(self):
        self.api.authenticate = MagicMock()
        with self.assertRaises(module.ReleaseError):
            self.api.get("https://attacker.example/builds")
        self.api.authenticate.assert_not_called()

    def test_version_filter_resolves_prerelease_id(self):
        self.api.collection = MagicMock(side_effect=[[{"id": "pre-1"}], []])
        self.api.builds("app-1", "1.0.1")
        params = self.api.collection.call_args.args[1]
        self.assertEqual(params["filter[preReleaseVersion]"], "pre-1")
        self.assertEqual(params["filter[preReleaseVersion.platform]"], "IOS")

    def test_jwt_generation_failure_never_exposes_output(self):
        with patch.object(
            module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "secret", "secret")
        ):
            with self.assertRaises(module.ReleaseError) as error:
                self.api.authenticate()
        self.assertNotIn("secret", str(error.exception))

    def test_token_is_cached_and_refreshed(self):
        token = "eyJtest.abc.def"
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, token, "")) as run:
            self.assertEqual(self.api.authenticate(), token)
            self.assertEqual(self.api.authenticate(), token)
            self.assertEqual(run.call_count, 1)
            self.api.token_at -= 601
            self.api.authenticate()
            self.assertEqual(run.call_count, 2)


class TestRelease(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project.yml"
        self.project.write_text(
            'settings:\n  base:\n    MARKETING_VERSION: "1.0.0"\n    CURRENT_PROJECT_VERSION: "1"\n'
        )
        self.output = self.root / "output"
        for target, value in (("SPEC", self.project), ("OUTPUT", self.output)):
            patcher = patch.object(module, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.api = MagicMock()
        self.api.app_id.return_value = "123"
        self.api.versions.return_value = []
        self.api.builds.side_effect = [
            [],
            [
                {
                    "id": "build",
                    "attributes": {"version": "2", "processingState": "VALID", "usesNonExemptEncryption": False},
                }
            ],
        ]
        self.commands = []

    def command(self, argv, log, title):
        self.commands.append(argv)
        log.write_text(title)
        if "archive" in argv:
            archive = Path(argv[argv.index("-archivePath") + 1])
            app = archive / "Products/Applications/BusWidget.app"
            for bundle, identifier in (
                (app, module.BUNDLE_ID),
                (app / "PlugIns/BusWidgetExtension.appex", module.BUNDLE_ID + ".BusWidgetExtension"),
            ):
                bundle.mkdir(parents=True, exist_ok=True)
                with (bundle / "Info.plist").open("wb") as file:
                    plistlib.dump(
                        {
                            "CFBundleIdentifier": identifier,
                            "CFBundleVersion": "2",
                            "CFBundleShortVersionString": "1.0.1",
                            "APIBaseURL": module.API_URL,
                        },
                        file,
                    )
        if "-exportArchive" in argv:
            export = Path(argv[argv.index("-exportPath") + 1])
            export.mkdir()
            (export / "BusWidget.ipa").write_bytes(b"fake")

    def invoke(self):
        with patch.object(module, "run_command", side_effect=self.command), redirect_stdout(io.StringIO()):
            module.release(self.api, module.Credentials("id", "issuer", Path("/tmp/key.p8")), "iPhone 17 Pro", 1)

    def test_test_archive_export_upload_and_completion(self):
        self.invoke()
        flattened = [" ".join(argv) for argv in self.commands]
        self.assertIn(" test ", flattened[1])
        self.assertIn(" archive ", flattened[2])
        self.assertIn("-exportArchive", flattened[3])
        self.assertIn("--upload-package", flattened[4])
        self.assertIn("API_BASE_URL=" + module.API_URL, flattened[2])
        self.assertEqual(module.project_versions(), ("1.0.1", "2"))
        directory, state = module.states()[0]
        self.assertEqual(state["phase"], "complete")
        with (directory / "ExportOptions.plist").open("rb") as file:
            options = plistlib.load(file)
        self.assertFalse(options["manageAppVersionAndBuildNumber"])
        self.assertFalse(options["testFlightInternalTestingOnly"])

    def test_failed_tests_prevent_archive_and_upload(self):
        def fail(argv, log, title):
            if "test" in argv:
                raise module.ReleaseError("tests failed")
            self.command(argv, log, title)

        with patch.object(module, "run_command", side_effect=fail), redirect_stdout(io.StringIO()):
            with self.assertRaises(module.ReleaseError):
                module.release(self.api, module.Credentials("id", "issuer", Path("/tmp/key.p8")), "sim", 1)
        self.assertFalse(any("archive" in argv or "--upload-package" in argv for argv in self.commands))
        self.assertEqual(module.project_versions(), ("1.0.0", "1"))
        self.assertFalse(module.states()[0][1]["reserved"])

    def test_upload_failure_reserves_version_but_does_not_edit_project(self):
        original_command = self.command

        def fail(argv, log, title):
            if "--upload-package" in argv:
                raise module.ReleaseError("upload connection lost")
            original_command(argv, log, title)

        self.command = fail
        with self.assertRaises(module.ReleaseError):
            self.invoke()
        self.assertTrue(module.states()[0][1]["reserved"])
        self.assertEqual(module.project_versions(), ("1.0.0", "1"))

    def test_missing_and_processing_states_timeout_without_reupload(self):
        self.api.builds.side_effect = None
        self.api.builds.return_value = []
        directory = self.root / "pending"
        directory.mkdir()
        state = {"app_id": "123", "version": "1.0.1", "build": "2", "source_versions": ["1.0.0", "1"], "reserved": True}
        with patch.object(module.time, "monotonic", side_effect=[0, 2]), redirect_stdout(io.StringIO()):
            with self.assertRaises(module.ReleaseError):
                module.wait_for_build(self.api, state, directory, 1)
        self.assertEqual(json.loads((directory / "release.json").read_text())["processing_state"], "NOT_VISIBLE")
        self.assertEqual(module.project_versions(), ("1.0.0", "1"))

    def test_status_resumes_without_reupload(self):
        directory = self.root / "resume"
        directory.mkdir()
        state = {
            "app_id": "123",
            "version": "1.0.1",
            "build": "2",
            "source_versions": ["1.0.0", "1"],
            "reserved": True,
            "phase": "uploaded",
        }
        module.save_state(directory, state)
        self.api.builds.side_effect = None
        self.api.builds.return_value = [
            {"attributes": {"version": "2", "processingState": "VALID", "usesNonExemptEncryption": False}}
        ]
        with patch.object(module, "run_command", side_effect=self.command), redirect_stdout(io.StringIO()):
            module.wait_for_build(self.api, json.loads((directory / "release.json").read_text()), directory, 1)
        self.assertFalse(any("--upload-package" in argv for argv in self.commands))
        self.assertEqual(module.project_versions(), ("1.0.1", "2"))
        self.assertEqual(json.loads((directory / "release.json").read_text())["phase"], "complete")

    def test_processing_failure_is_not_success(self):
        directory = self.root / "failed"
        directory.mkdir()
        self.api.builds.side_effect = None
        self.api.builds.return_value = [{"attributes": {"version": "2", "processingState": "INVALID"}}]
        state = {"app_id": "123", "version": "1.0.1", "build": "2"}
        with redirect_stdout(io.StringIO()), self.assertRaises(module.ReleaseError):
            module.wait_for_build(self.api, state, directory, 1)
        self.assertEqual(state["phase"], "processing_failed")

    def test_archive_rejects_widget_version_mismatch(self):
        archive = self.root / "archive"
        self.command(["archive", "-archivePath", str(archive)], self.root / "log", "archive")
        info = archive / "Products/Applications/BusWidget.app/PlugIns/BusWidgetExtension.appex/Info.plist"
        data = plistlib.loads(info.read_bytes())
        data["CFBundleVersion"] = "1"
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaises(module.ReleaseError):
            module.verify_archive(archive, "1.0.1", "2")

    def test_sync_does_not_overwrite_newer_work(self):
        self.project.write_text('    MARKETING_VERSION: "2.0.0"\n    CURRENT_PROJECT_VERSION: "20"\n')
        with patch.object(module, "run_command") as run, redirect_stdout(io.StringIO()):
            module.sync_project({"source_versions": ["1.0.0", "1"], "version": "1.0.1", "build": "2"}, self.root)
        run.assert_not_called()
        self.assertEqual(module.project_versions(), ("2.0.0", "20"))


class TestCredentials(unittest.TestCase):
    def test_environment_overrides_file_and_rejects_key_inside_repo(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            config = root / "config.json"
            key = root / "key.p8"
            key.write_text("fake")
            config.write_text(json.dumps({"key_id": "file", "issuer_id": "issuer", "key_path": str(key)}))
            with patch.dict(module.os.environ, {"ASC_KEY_ID": "environment"}, clear=True):
                self.assertEqual(module.Credentials.load(config).key_id, "environment")
                with patch.object(module, "ROOT", root), self.assertRaises(module.ReleaseError):
                    module.Credentials.load(config)


class TestRedaction(unittest.TestCase):
    def test_command_log_redaction_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "command.log"
            program = "print('eyJabc.def.ghi'); print('-----BEGIN PRIVATE KEY-----'); print('private'); print('-----END PRIVATE KEY-----'); raise SystemExit(7)"
            with redirect_stdout(io.StringIO()), self.assertRaises(module.ReleaseError):
                module.run_command([sys.executable, "-c", program], log, "test command")
            self.assertNotIn("private", log.read_text())
            self.assertNotIn("eyJabc", log.read_text())

    def test_secrets(self):
        value = "token eyJabc.def.ghi\n-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----"
        result = module.redact(value)
        self.assertNotIn("eyJabc", result)
        self.assertNotIn("secret", result)


if __name__ == "__main__":
    unittest.main()
