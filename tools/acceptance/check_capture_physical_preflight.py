#!/usr/bin/env python3
"""Report partial capture-test prerequisites without claiming physical readiness.

This read-only command inspects Xcode's device inventory and source text. It
does not verify pairing, XCTest registration, signing, installation, device
permissions, physical controls, or any test outcome. Device names and IDs are
never emitted. A blocked result is not an acceptance receipt.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any


REQUIRED_TEST_NAMES = (
    "testLockedScreenCaptureContinuesOnDevice",
    "testIncomingCallPausesAndResumesCaptureOnDevice",
    "testWatchRelayAndHapticStatusOnDevice",
)
UNVERIFIED = (
    "authorized_device_identity",
    "device_pairing",
    "test_registration_and_behavior",
    "signing_and_provisioning",
    "installation_and_permissions",
    "physical_control_and_observation",
    "exact_build_identity",
    "test_execution_and_results",
)
MAX_INVENTORY_BYTES = 2 * 1024 * 1024
MAX_SOURCE_BYTES = 2 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCES = (
    ROOT / "Yggdrasil/YggdrasilUITests/HeimdalCaptureJourneyTests.swift",
)


def _version(value: object) -> tuple[tuple[int, ...], str] | None:
    if not isinstance(value, str) or len(value) > 64:
        return None
    match = re.match(r"^([0-9]{1,3}(?:\.[0-9]{1,3}){0,3})(?:\s|$)", value)
    if match is None:
        return None
    parts = tuple(int(part) for part in match.group(1).split("."))
    return parts + (0,) * max(0, 2 - len(parts)), match.group(1)


def _candidate(devices: list[dict[str, Any]], role: str) -> dict[str, str]:
    def matches(device: dict[str, Any]) -> bool:
        model = device.get("modelName")
        code = device.get("modelCode")
        model = model if isinstance(model, str) else ""
        code = code if isinstance(code, str) else ""
        if role == "iphone":
            return model.casefold() == "iphone 12" or code.casefold() == "iphone13,2"
        return re.match(r"^(?:apple )?watch se(?:\s|\(|$)", model, re.IGNORECASE) is not None

    platform = "com.apple.platform.iphoneos" if role == "iphone" else "com.apple.platform.watchos"
    minimum = (17, 0) if role == "iphone" else (10, 0)
    family = "iPhone 12" if role == "iphone" else "Apple Watch SE"
    matching = [device for device in devices if matches(device)]
    available = [
        device for device in matching
        if device.get("simulator") is False
        and device.get("available") is True
        and isinstance(device.get("platform"), str)
        and platform == device["platform"].casefold()
    ]
    if not matching:
        return {"state": "missing", "model_family": family}
    if not available:
        return {"state": "unavailable", "model_family": family}
    if len(available) != 1:
        return {"state": "ambiguous", "model_family": family}
    version = _version(available[0].get("operatingSystemVersion"))
    if version is None:
        return {"state": "os_unknown", "model_family": family}
    return {
        "state": "candidate" if version[0] >= minimum else "os_unsupported",
        "model_family": family,
        "os_version": version[1],
    }


def build_report(
    inventory: object,
    source_texts: list[str],
    *,
    inventory_problem: str | None = None,
    sources_incomplete: bool = False,
) -> dict[str, Any]:
    """Return only allowlisted observations; neither names nor IDs survive."""
    problems: list[str] = []
    if inventory_problem is not None:
        problems.append("inventory_unavailable")
        devices: list[dict[str, Any]] = []
    elif not isinstance(inventory, list) or any(not isinstance(item, dict) for item in inventory):
        problems.append("inventory_malformed")
        devices = []
    else:
        devices = inventory
    if sources_incomplete:
        problems.append("source_observation_incomplete")
    candidates = {role: _candidate(devices, role) for role in ("iphone", "watch")}
    for role, observation in candidates.items():
        if observation["state"] != "candidate":
            problems.append(role + "_" + observation["state"])
    names = {
        name: any(name in text for text in source_texts)
        for name in REQUIRED_TEST_NAMES
    }
    if not all(names.values()):
        problems.append("required_test_names_not_observed")
    problems.append("physical_qualification_not_established")
    return {
        "status": "BLOCKED",
        "candidates": candidates,
        "source_name_mentions": names,
        "unverified": list(UNVERIFIED),
        "blockers": sorted(set(problems)),
    }


def inspect_inventory() -> tuple[object, str | None]:
    try:
        result = subprocess.run(
            ["xcrun", "xcdevice", "list"], capture_output=True, timeout=20, check=False,
        )
        if result.returncode != 0 or len(result.stdout) > MAX_INVENTORY_BYTES:
            return None, "unavailable"
        return json.loads(result.stdout), None
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError, ValueError, RecursionError):
        return None, "unavailable"


def inspect_sources(paths: list[Path]) -> tuple[list[str], bool]:
    texts: list[str] = []
    incomplete = False
    for path in paths:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            try:
                source = os.fdopen(descriptor, "rb")
            except BaseException:
                os.close(descriptor)
                raise
            with source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    raise ValueError
                raw = source.read(MAX_SOURCE_BYTES + 1)
            if len(raw) > MAX_SOURCE_BYTES:
                raise ValueError
            texts.append(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            incomplete = True
    return texts, incomplete


class RedactedArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse's default error echoes untrusted arguments and private paths.
        self.exit(2, "invalid arguments\n")


def main(argv: list[str] | None = None) -> int:
    parser = RedactedArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", action="append", type=Path, default=None,
        help="Regular source file to inspect for name mentions; repeatable. Names do not prove registration.",
    )
    args = parser.parse_args(argv)
    inventory, problem = inspect_inventory()
    texts, incomplete = inspect_sources(args.source if args.source is not None else list(DEFAULT_SOURCES))
    report = build_report(inventory, texts, inventory_problem=problem, sources_incomplete=incomplete)
    print(json.dumps(report, sort_keys=True))
    return 2  # Physical qualification remains unverified by this inspection.


if __name__ == "__main__":
    sys.exit(main())
