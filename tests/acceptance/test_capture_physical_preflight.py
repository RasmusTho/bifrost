from __future__ import annotations

from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools.acceptance import check_capture_physical_preflight as preflight


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/acceptance/check_capture_physical_preflight.py"


def device(model: str, code: str, platform: str, version: str) -> dict[str, object]:
    return {
        "modelName": model,
        "modelCode": code,
        "platform": platform,
        "operatingSystemVersion": version,
        "available": True,
        "simulator": False,
        "name": "private-device-name",
        "identifier": "private-identifier",
    }


def pair() -> list[dict[str, object]]:
    return [
        device("iPhone 12", "iPhone13,2", "com.apple.platform.iphoneos", "18.7.1 (22H31)"),
        device("Apple Watch SE (40mm)", "Watch5,9", "com.apple.platform.watchos", "11.6.1"),
    ]


class PhysicalPreflightTests(unittest.TestCase):
    def test_candidate_observations_never_claim_qualification(self) -> None:
        # A comment or unrelated string is only a mention, not a registered test.
        source = "\n".join("// " + name for name in preflight.REQUIRED_TEST_NAMES)
        output = io.StringIO()
        with patch.object(preflight, "inspect_inventory", return_value=(pair(), None)):
            with patch.object(preflight, "inspect_sources", return_value=([source], False)):
                with redirect_stdout(output):
                    self.assertEqual(preflight.main([]), 2)
        report = json.loads(output.getvalue())
        self.assertEqual(report["status"], "BLOCKED")
        self.assertEqual(report["candidates"]["iphone"]["state"], "candidate")
        self.assertEqual(report["candidates"]["watch"]["state"], "candidate")
        self.assertTrue(all(report["source_name_mentions"].values()))
        self.assertIn("test_registration_and_behavior", report["unverified"])
        self.assertIn("device_pairing", report["unverified"])
        self.assertIn("physical_qualification_not_established", report["blockers"])
        encoded = json.dumps(report)
        self.assertNotIn("private-device-name", encoded)
        self.assertNotIn("private-identifier", encoded)
        ambiguous = pair()
        ambiguous.append(dict(ambiguous[0]))
        ambiguous[1]["operatingSystemVersion"] = "9.6"
        output = io.StringIO()
        with patch.object(preflight, "inspect_inventory", return_value=(ambiguous, None)):
            with patch.object(preflight, "inspect_sources", return_value=([], False)):
                with redirect_stdout(output):
                    self.assertEqual(preflight.main([]), 2)
        blocked = json.loads(output.getvalue())
        self.assertEqual(blocked["candidates"]["iphone"]["state"], "ambiguous")
        self.assertEqual(blocked["candidates"]["watch"]["state"], "os_unsupported")
        self.assertIn("required_test_names_not_observed", blocked["blockers"])

    def test_inventory_failures_are_redacted_and_blocked(self) -> None:
        with patch.object(preflight.subprocess, "run", side_effect=OSError("secret-error-detail")):
            inventory, problem = preflight.inspect_inventory()
        report = preflight.build_report(inventory, [], inventory_problem=problem, sources_incomplete=True)
        self.assertEqual(report["status"], "BLOCKED")
        self.assertIn("inventory_unavailable", report["blockers"])
        self.assertIn("source_observation_incomplete", report["blockers"])
        self.assertNotIn("secret-error-detail", json.dumps(report))
        malformed = preflight.build_report([{"name": "secret"}, "private-value"], [])
        self.assertIn("inventory_malformed", malformed["blockers"])
        self.assertNotIn("private-value", json.dumps(malformed))
        invalid_json = subprocess.CompletedProcess([], 0, stdout=b"{private-device-name", stderr=b"")
        with patch.object(preflight.subprocess, "run", return_value=invalid_json):
            parsed, issue = preflight.inspect_inventory()
        self.assertIsNone(parsed)
        self.assertEqual(issue, "unavailable")
        output = io.StringIO()
        with patch.object(preflight.subprocess, "run", return_value=invalid_json):
            with patch.object(preflight, "inspect_sources", return_value=([], True)):
                with redirect_stdout(output):
                    self.assertEqual(preflight.main([]), 2)
        self.assertIn("inventory_unavailable", json.loads(output.getvalue())["blockers"])
        self.assertNotIn("private-device-name", output.getvalue())
        nested_json = b"[" * 100000 + b"]" * 100000
        nested_result = subprocess.CompletedProcess([], 0, stdout=nested_json, stderr=b"")
        with patch.object(preflight.subprocess, "run", return_value=nested_result):
            parsed, issue = preflight.inspect_inventory()
        nested_report = preflight.build_report(parsed, [], inventory_problem=issue)
        self.assertEqual(nested_report["status"], "BLOCKED")
        self.assertTrue(
            {"inventory_unavailable", "inventory_malformed"} & set(nested_report["blockers"])
        )
        with patch.object(preflight.subprocess, "run", return_value=nested_result):
            with patch.object(preflight.json, "loads", side_effect=RecursionError):
                parsed, issue = preflight.inspect_inventory()
        self.assertIsNone(parsed)
        self.assertEqual(issue, "unavailable")
        with patch.object(preflight.subprocess, "run", return_value=nested_result):
            with patch.object(preflight.json, "loads", return_value=[[]]):
                parsed, issue = preflight.inspect_inventory()
        parsed_report = preflight.build_report(parsed, [], inventory_problem=issue)
        self.assertIn("inventory_malformed", parsed_report["blockers"])

    def test_ambiguous_old_and_simulated_devices_do_not_qualify(self) -> None:
        devices = pair()
        devices.append(dict(devices[0]))
        devices[1]["operatingSystemVersion"] = "9.6"
        report = preflight.build_report(devices, [])
        self.assertEqual(report["candidates"]["iphone"]["state"], "ambiguous")
        self.assertEqual(report["candidates"]["watch"]["state"], "os_unsupported")
        devices[1]["simulator"] = True
        self.assertEqual(preflight.build_report(devices, [])["candidates"]["watch"]["state"], "unavailable")

    def test_malformed_version_and_missing_cases_are_explicit(self) -> None:
        devices = pair()
        devices[0]["operatingSystemVersion"] = "private text 18.1"
        report = preflight.build_report(devices, [preflight.REQUIRED_TEST_NAMES[0]])
        self.assertEqual(report["candidates"]["iphone"]["state"], "os_unknown")
        self.assertFalse(report["source_name_mentions"][preflight.REQUIRED_TEST_NAMES[1]])
        self.assertIn("required_test_names_not_observed", report["blockers"])
        self.assertNotIn("private text", json.dumps(report))

    def test_real_cli_reads_fake_inventory_without_exposing_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "xcrun"
            binary.write_text("#!/bin/sh\nprintf '%s' '" + json.dumps(pair()) + "'\n", encoding="utf-8")
            binary.chmod(0o755)
            source = root / "private-source-path.swift"
            source.write_text("\n".join(preflight.REQUIRED_TEST_NAMES), encoding="utf-8")
            env = os.environ.copy()
            env["PATH"] = str(root) + os.pathsep + env.get("PATH", "")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--source", str(source)],
                capture_output=True, text=True, env=env, check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["status"], "BLOCKED")
        self.assertNotIn("private-identifier", result.stdout + result.stderr)
        self.assertNotIn("private-source-path", result.stdout + result.stderr)

    def test_cli_help_and_ci_test_entry(self) -> None:
        help_result = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, check=False,
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("does not verify pairing", help_result.stdout)
        invalid = subprocess.run(
            [sys.executable, str(SCRIPT), "--unknown", "/tmp/private-source-path"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(invalid.stderr, "invalid arguments\n")
        self.assertNotIn("private-source-path", invalid.stdout + invalid.stderr)
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("python3 -m unittest discover -s tests/acceptance", workflow)

    def test_named_pipe_source_is_refused_without_waiting_for_writer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "xcrun"
            binary.write_text("#!/bin/sh\nprintf '%s' '[]'\n", encoding="utf-8")
            binary.chmod(0o755)
            fifo = root / "private-source-pipe"
            os.mkfifo(fifo)
            env = os.environ.copy()
            env["PATH"] = str(root) + os.pathsep + env.get("PATH", "")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--source", str(fifo)],
                capture_output=True, text=True, env=env, timeout=4, check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("source_observation_incomplete", json.loads(result.stdout)["blockers"])
        self.assertNotIn("private-source-pipe", result.stdout + result.stderr)

    def test_source_symlink_is_not_followed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "private-content"
            source.write_text(preflight.REQUIRED_TEST_NAMES[0], encoding="utf-8")
            link = root / "source.swift"
            link.symlink_to(source)
            observed, incomplete = preflight.inspect_sources([link])
        self.assertEqual(observed, [])
        self.assertTrue(incomplete)

    def test_main_uses_fixed_diagnostics_when_inventory_fails(self) -> None:
        output = io.StringIO()
        with patch.object(preflight, "inspect_inventory", return_value=(None, "private error")):
            with patch.object(preflight, "inspect_sources", return_value=([], True)):
                with redirect_stdout(output):
                    status = preflight.main([])
        self.assertEqual(status, 2)
        self.assertNotIn("private error", output.getvalue())
        self.assertIn("inventory_unavailable", json.loads(output.getvalue())["blockers"])


if __name__ == "__main__":
    unittest.main()
