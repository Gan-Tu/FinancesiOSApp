#!/usr/bin/env python3
"""Validate capability bookkeeping against native target entitlements.

XcodeGen 2.46.0 stringifies nested target attributes (upstream #1637):
https://github.com/yonaskolb/XcodeGen/issues/1637
--repair-generated converts only that exact generated SystemCapabilities shape.
Already-correct dictionaries are unchanged, so future fixed generators are safe.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'\s*"([A-Za-z0-9_.-]+)"\s*:\s*\[\s*"enabled"\s*:\s*([01])\s*\]\s*')
QUOTED_CAPABILITIES = re.compile(r'(?m)^(?P<indent>[ \t]*)SystemCapabilities\s*=\s*(?P<value>"(?:[^"\\]|\\.)*");[ \t]*$')


def read_project(raw: bytes) -> dict:
    converted = subprocess.run(
        ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", "-"],
        input=raw, capture_output=True, check=True,
    )
    return plistlib.loads(converted.stdout)


def target_attributes(project: dict) -> dict:
    return project["objects"][project["rootObject"]].get("attributes", {}).get("TargetAttributes", {})


def descriptor(value: str) -> dict:
    if not value.startswith("[") or not value.endswith("]"):
        raise ValueError("Unknown generated capability string; refusing to guess its structure")
    result = {}
    remaining = value[1:-1]
    while remaining.strip():
        match = ENTRY.match(remaining)
        if match is None or match[1] in result:
            raise ValueError("Malformed or duplicate generated capability entry")
        result[match[1]] = {"enabled": match[2]}
        remaining = remaining[match.end():]
        if remaining:
            if not remaining.startswith(","):
                raise ValueError("Unsupported data inside generated capability string")
            remaining = remaining[1:]
    return result


def outside_capabilities(project: dict) -> dict:
    result = copy.deepcopy(project)
    for attributes in target_attributes(result).values():
        attributes.pop("SystemCapabilities", None)
    return result


def normalize(raw: bytes) -> bytes:
    before = read_project(raw)
    expected = {
        key: descriptor(value["SystemCapabilities"])
        for key, value in target_attributes(before).items()
        if isinstance(value.get("SystemCapabilities"), str)
    }
    if not expected:
        return raw

    def replacement(match: re.Match) -> str:
        capabilities = descriptor(json.loads(match["value"]))
        indent = match["indent"]
        lines = [indent + "SystemCapabilities = {"]
        for name, value in sorted(capabilities.items()):
            lines += [indent + "\t" + name + " = {", indent + "\t\tenabled = " + value["enabled"] + ";", indent + "\t};"]
        lines.append(indent + "};")
        return "\n".join(lines)

    changed = QUOTED_CAPABILITIES.sub(replacement, raw.decode("utf-8")).encode("utf-8")
    after = read_project(changed)
    if outside_capabilities(before) != outside_capabilities(after):
        raise ValueError("Repair would alter unrelated project attributes; no changes written")
    for key, value in expected.items():
        if target_attributes(after).get(key, {}).get("SystemCapabilities") != value:
            raise ValueError("Capability repair did not preserve the requested enabled values")
    return changed


def referenced_plist(project_root: Path, value: str | None) -> dict:
    if not value:
        return {}
    value = value.removeprefix("$(SRCROOT)/").removeprefix("$(PROJECT_DIR)/")
    if "$(" in value:
        raise ValueError("Unresolved plist path in native target configuration")
    path = (project_root / value).resolve()
    if not path.is_relative_to(project_root.resolve()):
        raise ValueError("Native plist path is outside the repository")
    return plistlib.loads(path.read_bytes())


def validate(raw: bytes, project_root: Path) -> list[str]:
    project = read_project(raw)
    objects = project["objects"]
    attributes = target_attributes(project)
    checked = []
    for target_id, target in objects.items():
        if target.get("isa") != "PBXNativeTarget":
            continue
        needed = set()
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for identifier in configurations:
            settings = objects[identifier].get("buildSettings", {})
            entitlements = referenced_plist(project_root, settings.get("CODE_SIGN_ENTITLEMENTS"))
            info = referenced_plist(project_root, settings.get("INFOPLIST_FILE"))
            if "CloudKit" in entitlements.get("com.apple.developer.icloud-services", []):
                needed.add("com.apple.iCloud")
            if "aps-environment" in entitlements or "com.apple.developer.aps-environment" in entitlements:
                needed.add("com.apple.Push")
            if entitlements.get("com.apple.security.app-sandbox") is True:
                needed.add("com.apple.Sandbox")
            if "remote-notification" in info.get("UIBackgroundModes", []):
                needed.add("com.apple.BackgroundModes")
        capabilities = attributes.get(target_id, {}).get("SystemCapabilities", {})
        if not isinstance(capabilities, dict):
            raise ValueError(f"{target['name']}: SystemCapabilities must be a dictionary, not {type(capabilities).__name__}")
        for name, value in capabilities.items():
            if not isinstance(value, dict) or value.get("enabled") not in ("0", "1", 0, 1):
                raise ValueError(f"{target['name']}: {name} must contain a native enabled value")
        for name in sorted(needed):
            if capabilities.get(name, {}).get("enabled") not in ("1", 1):
                raise ValueError(f"{target['name']}: {name} is missing/disabled despite its plist declarations")
        if needed:
            checked.append(target["name"])
    if not checked:
        raise ValueError("No native entitlement-bearing targets were validated")
    return sorted(checked)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repair-generated", action="store_true")
    parser.add_argument("--project", type=Path, default=ROOT / "FinancesiOS.xcodeproj/project.pbxproj")
    args = parser.parse_args()
    path = args.project.resolve()
    try:
        original = path.read_bytes()
        checked = normalize(original) if args.repair_generated else original
        targets = validate(checked, path.parent.parent)
        if checked != original:
            path.write_bytes(checked)
        print("Xcode capabilities validated: " + ", ".join(targets))
        return 0
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print("Xcode capability validation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
