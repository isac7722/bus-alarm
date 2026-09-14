#!/usr/bin/env python3
"""Build, upload and monitor this app using Xcode and Python's standard library."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"
OUTPUT = IOS / "build" / "testflight"
SPEC = IOS / "project.yml"
PROJECT = IOS / "BusWidget.xcodeproj"
BUNDLE_ID = "com.pangjoong.BusWidget"
TEAM_ID = "K5M43RRH97"
API_URL = "https://bus.pangjoong.com"
ASC_URL = "https://api.appstoreconnect.apple.com"
TOKEN_PATTERN = re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")


class ReleaseError(Exception):
    """An actionable deployment error safe to display without credentials."""


@dataclass(frozen=True)
class Credentials:
    """Team API key identifiers and an external private key path."""

    key_id: str
    issuer_id: str
    key_path: Path

    @classmethod
    def load(cls, path: Path) -> Credentials:
        """Read a local JSON file, with environment variables taking precedence."""
        values: dict[str, Any] = {}
        if path.exists():
            try:
                values = json.loads(path.read_text())
            except (ValueError, OSError) as error:
                raise ReleaseError(f"설정 JSON을 읽을 수 없습니다: {path}") from error
            if not isinstance(values, dict):
                raise ReleaseError("설정은 JSON 객체여야 합니다.")
        key_id = os.environ.get("ASC_KEY_ID", values.get("key_id", ""))
        issuer_id = os.environ.get("ASC_ISSUER_ID", values.get("issuer_id", ""))
        key_path = os.environ.get("ASC_KEY_PATH", values.get("key_path", ""))
        if not all(isinstance(v, str) and v for v in (key_id, issuer_id, key_path)):
            raise ReleaseError("API 키 설정이 필요합니다. README.md의 TestFlight 배포 설정을 진행하세요.")
        path_value = Path(key_path).expanduser().resolve()
        if not path_value.is_file():
            raise ReleaseError(f"API 개인 키 파일이 없습니다: {path_value}")
        if path_value == ROOT or ROOT in path_value.parents:
            raise ReleaseError(".p8 개인 키는 Git 저장소 밖에 보관하세요.")
        return cls(key_id, issuer_id, path_value)

    def upload_args(self) -> list[str]:
        """Return altool's supported team-key authentication flags."""
        return ["--api-key", self.key_id, "--api-issuer", self.issuer_id, "--p8-file-path", str(self.key_path)]

    def signing_args(self) -> list[str]:
        """Allow Xcode to manage signing profiles using the same team key."""
        return [
            "-allowProvisioningUpdates",
            "-authenticationKeyPath",
            str(self.key_path),
            "-authenticationKeyID",
            self.key_id,
            "-authenticationKeyIssuerID",
            self.issuer_id,
        ]


def redact(value: str) -> str:
    """Remove JWTs and private-key blocks before saving tool output."""
    value = TOKEN_PATTERN.sub("[REDACTED JWT]", value)
    return re.sub(
        r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
        "[REDACTED PRIVATE KEY]",
        value,
        flags=re.DOTALL,
    )


def run_command(command: list[str], log: Path, title: str) -> None:
    """Run a command without a shell and retain diagnostics in a private log."""
    print(f"[{title}] 시작 — 로그: {log}", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            start_new_session=True,
        )
        try:
            assert process.stdout is not None
            private_block = False
            for line in process.stdout:
                if "-----BEGIN " in line and "PRIVATE KEY-----" in line:
                    private_block = True
                    output.write("[REDACTED PRIVATE KEY]\n")
                elif not private_block:
                    output.write(redact(line))
                if "-----END " in line and "PRIVATE KEY-----" in line:
                    private_block = False
                output.flush()
            code = process.wait()
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
        finally:
            if process.stdout is not None:
                process.stdout.close()
    if code:
        raise ReleaseError(f"{title} 실패(exit {code}). 로그 확인: {log}")
    print(f"[{title}] 완료", flush=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward API credentials to another endpoint via a redirect."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


class AppStoreConnect:
    """Read app metadata and build processing state with short-lived JWTs."""

    def __init__(self, credentials: Credentials) -> None:
        self.credentials = credentials
        self.token = ""
        self.token_at = 0.0
        self.opener = urllib.request.build_opener(NoRedirect())

    def authenticate(self) -> str:
        """Use Apple's local signing command; never persist its JWT output."""
        if self.token and time.monotonic() - self.token_at < 600:
            return self.token
        result = subprocess.run(
            ["xcrun", "altool", "--generate-jwt", *self.credentials.upload_args()],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        matches = TOKEN_PATTERN.findall(result.stdout + result.stderr)
        if result.returncode or not matches:
            raise ReleaseError("API JWT 생성 실패: 팀 API 키의 Key ID, Issuer ID와 .p8 파일을 확인하세요.")
        self.token, self.token_at = matches[0], time.monotonic()
        return self.token

    def get(self, path: str, params: dict[str, str] | None = None) -> dict[str, Any]:
        """GET Apple JSON with bounded retries and no credential-bearing logging."""
        url = ASC_URL + path if path.startswith("/") else path
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com":
            raise ReleaseError("App Store Connect 응답에 허용되지 않은 페이지 주소가 있습니다.")
        if params:
            url += "?" + urllib.parse.urlencode(params)
        for attempt in range(4):
            request = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.authenticate()})
            try:
                with self.opener.open(request, timeout=30) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                if error.code == 401 and attempt == 0:
                    self.token = ""
                    continue
                if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise ReleaseError(
                    f"App Store Connect 조회 실패(HTTP {error.code}). 키 권한·앱 등록을 확인하세요."
                ) from error
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt < 3:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise ReleaseError("App Store Connect 네트워크 조회에 실패했습니다.") from error
        raise ReleaseError("App Store Connect 인증에 실패했습니다.")

    def collection(self, path: str, params: dict[str, str]) -> list[dict[str, Any]]:
        """Follow every result page instead of assuming version ordering is numeric."""
        result = self.get(path, {**params, "limit": "200"})
        values = list(result["data"])
        seen: set[str] = set()
        while result.get("links", {}).get("next"):
            next_url = result["links"]["next"]
            if next_url in seen:
                raise ReleaseError("App Store Connect 페이지가 반복됩니다.")
            seen.add(next_url)
            result = self.get(next_url)
            values.extend(result["data"])
        return values

    def app_id(self) -> str:
        """Resolve the existing app record by the project's bundle identifier."""
        apps = self.collection("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId,name"})
        if len(apps) != 1:
            raise ReleaseError(f"App Store Connect에 {BUNDLE_ID} 앱을 먼저 등록하거나 키의 앱 접근 권한을 확인하세요.")
        return str(apps[0]["id"])

    def versions(self, app_id: str) -> list[str]:
        """Read all iOS prerelease marketing versions, including expired versions."""
        rows = self.collection(
            "/v1/preReleaseVersions",
            {"filter[app]": app_id, "filter[platform]": "IOS", "fields[preReleaseVersions]": "version"},
        )
        return [row["attributes"]["version"] for row in rows]

    def builds(self, app_id: str, version: str | None = None) -> list[dict[str, Any]]:
        """Read iOS builds; resolve a prerelease ID before filtering its build list."""
        params = {
            "filter[app]": app_id,
            "filter[preReleaseVersion.platform]": "IOS",
            "fields[builds]": "version,processingState,usesNonExemptEncryption",
        }
        if version:
            versions = self.collection(
                "/v1/preReleaseVersions", {"filter[app]": app_id, "filter[platform]": "IOS", "filter[version]": version}
            )
            if not versions:
                return []
            params["filter[preReleaseVersion]"] = ",".join(row["id"] for row in versions)
        return self.collection("/v1/builds", params)


def version_tuple(value: str) -> tuple[int, int, int]:
    """Normalize Apple's one-to-three numeric marketing version components."""
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value, flags=re.ASCII):
        raise ReleaseError(f"숫자 버전 형식이 아닙니다: {value}")
    parts = [int(part) for part in value.split(".")]
    padded = parts + [0, 0]
    return padded[0], padded[1], padded[2]


def project_versions() -> tuple[str, str]:
    """Read the single source of truth in XcodeGen's project specification."""
    text = SPEC.read_text()
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        matches = re.findall(rf'^    {key}:\s*"?([0-9.]+)"?\s*$', text, re.MULTILINE)
        if len(matches) != 1:
            raise ReleaseError(f"ios/project.yml의 {key} 설정을 하나로 지정하세요.")
        values.append(matches[0])
    return values[0], values[1]


def next_versions(
    local: tuple[str, str], remote_versions: list[str], remote_builds: list[str], reserved: list[dict[str, Any]]
) -> tuple[str, str]:
    """Increment the highest known version and never reuse an attempted upload."""
    all_versions = [local[0], *remote_versions, *(s["version"] for s in reserved)]
    major, minor, patch = max(version_tuple(v) for v in all_versions)
    # A new integer major build component is greater than dotted historical build numbers too.
    build = max(version_tuple(v)[0] for v in [local[1], *remote_builds, *(s["build"] for s in reserved)]) + 1
    if build > 9999:
        raise ReleaseError("빌드 번호가 정수 범위 9999를 넘습니다. 빌드 번호 정책을 조정하세요.")
    return f"{major}.{minor}.{patch + 1}", str(build)


def save_state(directory: Path, state: dict[str, Any]) -> None:
    """Atomically checkpoint a release so status can be resumed without uploading."""
    temporary = directory / "release.json.tmp"
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(directory / "release.json")


def states() -> list[tuple[Path, dict[str, Any]]]:
    """Read previous release records in timestamp order."""
    records = []
    for path in sorted(OUTPUT.glob("*/release.json")):
        records.append((path.parent, json.loads(path.read_text())))
    return records


def verify_archive(archive: Path, version: str, build: str) -> None:
    """Check the app and widget versions, bundle IDs and production API address."""
    app = archive / "Products/Applications/BusWidget.app"
    for bundle, identifier in (
        (app, BUNDLE_ID),
        (app / "PlugIns/BusWidgetExtension.appex", BUNDLE_ID + ".BusWidgetExtension"),
    ):
        with (bundle / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        expected = {
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "APIBaseURL": API_URL,
        }
        for key, value in expected.items():
            if info.get(key) != value:
                raise ReleaseError(f"아카이브의 {bundle.name} {key}가 배포 설정과 다릅니다.")


def sync_project(state: dict[str, Any], directory: Path) -> None:
    """Persist a processed release without overwriting independently edited versions."""
    current = project_versions()
    target = state["version"], state["build"]
    if current not in (tuple(state["source_versions"]), target):
        print("프로젝트 버전이 별도로 변경되어 덮어쓰지 않았습니다. 배포 버전:", target, flush=True)
        return
    text = SPEC.read_text()
    for key, value in zip(("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"), target):
        text = re.sub(rf"^    {key}:.*$", f'    {key}: "{value}"', text, flags=re.MULTILINE)
    SPEC.write_text(text)
    run_command(["xcodegen", "generate", "--spec", str(SPEC)], directory / "sync-project.log", "프로젝트 버전 반영")


def wait_for_build(api: AppStoreConnect, state: dict[str, Any], directory: Path, timeout: int) -> None:
    """Wait for Apple's VALID/FAILED/INVALID result and checkpoint each observation."""
    deadline = time.monotonic() + timeout
    while True:
        rows = api.builds(state["app_id"], state["version"])
        matching = [row for row in rows if row["attributes"]["version"] == state["build"]]
        status = matching[0]["attributes"]["processingState"] if matching else "NOT_VISIBLE"
        state["processing_state"] = status
        save_state(directory, state)
        print(f"[Apple 처리] {state['version']} ({state['build']}): {status}", flush=True)
        if status == "VALID":
            state["phase"] = "complete"
            save_state(directory, state)
            sync_project(state, directory)
            print(
                f"TestFlight 처리 완료: https://appstoreconnect.apple.com/apps/{state['app_id']}/testflight", flush=True
            )
            if matching[0]["attributes"].get("usesNonExemptEncryption") is None:
                print("App Store Connect에서 수출 규정 준수 질문에 답변이 필요한지 확인하세요.", flush=True)
            return
        if status in ("FAILED", "INVALID"):
            state["phase"] = "processing_failed"
            save_state(directory, state)
            raise ReleaseError(f"Apple 빌드 처리 실패: {status}. App Store Connect의 오류 내용을 확인하세요.")
        if time.monotonic() >= deadline:
            raise ReleaseError(
                "처리 확인 시간이 초과되었습니다. 재업로드 없이 make testflight-status로 다시 확인하세요."
            )
        time.sleep(min(30, max(0, deadline - time.monotonic())))


def preflight() -> None:
    """Check local tooling without changing signing accounts or contacting Apple."""
    for tool in ("xcodebuild", "xcodegen", "xcrun"):
        if not shutil.which(tool):
            raise ReleaseError(f"필요한 도구가 없습니다: {tool}")
    result = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=False)
    if result.returncode:
        raise ReleaseError("전체 Xcode 설치와 xcode-select 설정을 확인하세요.")
    print(result.stdout.strip(), flush=True)


def release(api: AppStoreConnect, credentials: Credentials, simulator: str, timeout: int) -> None:
    """Test, archive, export, upload once, then wait for processing completion."""
    app_id = api.app_id()
    local = project_versions()
    reserved = [state for _, state in states() if state.get("reserved")]
    version, build = next_versions(
        local, api.versions(app_id), [row["attributes"]["version"] for row in api.builds(app_id)], reserved
    )
    directory = OUTPUT / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    directory.mkdir(parents=True, mode=0o700)
    state = {
        "app_id": app_id,
        "version": version,
        "build": build,
        "source_versions": list(local),
        "phase": "testing",
        "reserved": False,
    }
    save_state(directory, state)
    print(f"배포 예정: {version} ({build}) / API: {API_URL}\n결과 폴더: {directory}", flush=True)
    run_command(["xcodegen", "generate", "--spec", str(SPEC)], directory / "generate.log", "프로젝트 생성")
    common = ["xcodebuild", "-project", str(PROJECT), "-scheme", "BusWidget"]
    run_command(
        [
            *common,
            "test",
            "-configuration",
            "Debug",
            "-destination",
            f"platform=iOS Simulator,name={simulator}",
            "-derivedDataPath",
            str(directory / "DerivedData"),
            "-resultBundlePath",
            str(directory / "Tests.xcresult"),
            "CODE_SIGNING_ALLOWED=NO",
        ],
        directory / "test.log",
        "iOS 테스트",
    )
    state["phase"] = "archiving"
    save_state(directory, state)
    archive = directory / "BusWidget.xcarchive"
    run_command(
        [
            *common,
            "archive",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=iOS",
            "-archivePath",
            str(archive),
            "-derivedDataPath",
            str(directory / "DerivedData"),
            f"MARKETING_VERSION={version}",
            f"CURRENT_PROJECT_VERSION={build}",
            f"API_BASE_URL={API_URL}",
            f"DEVELOPMENT_TEAM={TEAM_ID}",
            *credentials.signing_args(),
        ],
        directory / "archive.log",
        "Release 아카이브",
    )
    verify_archive(archive, version, build)
    export_options = directory / "ExportOptions.plist"
    with export_options.open("wb") as file:
        plistlib.dump(
            {
                "method": "app-store-connect",
                "destination": "export",
                "teamID": TEAM_ID,
                "signingStyle": "automatic",
                "manageAppVersionAndBuildNumber": False,
                "uploadSymbols": True,
                "testFlightInternalTestingOnly": False,
            },
            file,
        )
    export_path = directory / "export"
    run_command(
        [
            "xcodebuild",
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportPath",
            str(export_path),
            "-exportOptionsPlist",
            str(export_options),
            *credentials.signing_args(),
        ],
        directory / "export.log",
        "IPA 내보내기",
    )
    ipas = list(export_path.glob("*.ipa"))
    if len(ipas) != 1:
        raise ReleaseError("내보낸 IPA 파일이 정확히 하나여야 합니다.")
    state.update(phase="uploading", reserved=True)
    save_state(directory, state)
    run_command(
        [
            "xcrun",
            "altool",
            "--upload-package",
            str(ipas[0]),
            "--type",
            "ios",
            "--apple-id",
            app_id,
            "--bundle-id",
            BUNDLE_ID,
            "--bundle-version",
            build,
            "--bundle-short-version-string",
            version,
            *credentials.upload_args(),
            "--output-format",
            "json",
        ],
        directory / "upload.log",
        "TestFlight 업로드",
    )
    state["phase"] = "uploaded"
    save_state(directory, state)
    wait_for_build(api, state, directory, timeout)


def main(argv: list[str] | None = None) -> int:
    """Expose release, check and resumable status commands."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("release", "check", "status"), nargs="?", default="release")
    parser.add_argument("--config", type=Path, default=IOS / "Config/TestFlight.local.json")
    parser.add_argument("--simulator", default="iPhone 17 Pro")
    parser.add_argument("--timeout", type=int, default=1800, help="Apple 처리 대기 제한(초)")
    parser.add_argument("--run", type=Path, help="status로 확인할 기존 결과 폴더")
    parser.add_argument("--dry-run", action="store_true", help="인증·테스트·빌드·업로드 없이 로컬 설정만 표시")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        if args.timeout < 1:
            raise ReleaseError("--timeout은 1초 이상이어야 합니다.")
        preflight()
        if args.dry_run:
            local = project_versions()
            print(f"현재 프로젝트: {local[0]} ({local[1]})\n앱: {BUNDLE_ID}\n서명 팀: {TEAM_ID}\nAPI: {API_URL}")
            print("순서: iOS 테스트 → Release 아카이브 → IPA 내보내기 → 업로드 → Apple 처리 확인")
            print("실행 시 원격·로컬 업로드 이력을 조회하여 패치 버전과 빌드 번호를 증가시킵니다.")
            return 0
        credentials = Credentials.load(args.config)
        api = AppStoreConnect(credentials)
        if args.command == "check":
            app_id = api.app_id()
            local = project_versions()
            next_version = next_versions(
                local,
                api.versions(app_id),
                [row["attributes"]["version"] for row in api.builds(app_id)],
                [state for _, state in states() if state.get("reserved")],
            )
            print(f"API 인증·앱 조회 성공: {app_id}\n다음 배포: {next_version[0]} ({next_version[1]})")
            print("서명 인증서·프로파일의 발급 가능 여부는 아카이브·내보내기 단계에서 확인됩니다.")
            return 0
        OUTPUT.mkdir(parents=True, exist_ok=True)
        with (OUTPUT / ".lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ReleaseError("다른 TestFlight 명령이 실행 중입니다.") from error
            if args.command == "status":
                previous = [(path, state) for path, state in states() if state.get("reserved")]
                if args.run:
                    directory = args.run.resolve()
                    state = json.loads((directory / "release.json").read_text())
                elif previous:
                    directory, state = previous[-1]
                else:
                    raise ReleaseError("상태를 확인할 업로드 기록이 없습니다.")
                if not state.get("reserved"):
                    raise ReleaseError("아직 업로드를 시도하지 않은 빌드입니다.")
                if api.app_id() != state["app_id"]:
                    raise ReleaseError("현재 API 키의 앱과 저장된 배포 기록이 다릅니다.")
                wait_for_build(api, state, directory, args.timeout)
            else:
                release(api, credentials, args.simulator, args.timeout)
        return 0
    except KeyboardInterrupt:
        print("\n중단했습니다. 업로드가 시작됐다면 make testflight-status로 결과를 확인하세요.", file=sys.stderr)
        return 130
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"오류: {redact(str(error))}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
