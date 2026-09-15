#!/usr/bin/env python3
"""Select an available iPhone by UDID, preparing a fresh CI device if needed."""
import argparse
import json
import re
import subprocess
import sys

PREFERRED_PHONE = "iPhone 17 Pro Max"


def version(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))


def inventory():
    result = subprocess.run(["xcrun", "simctl", "list", "--json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def available_runtimes(data):
    return sorted(
        (runtime for runtime in data.get("runtimes", [])
         if runtime.get("isAvailable") and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
         and version(runtime["version"]) >= (17,)),
        key=lambda runtime: version(runtime["version"]), reverse=True,
    )


def prepare(allow_install=False):
    data = inventory()
    runtimes = available_runtimes(data)
    if not runtimes and allow_install:
        print("No available iOS runtime; installing one for the selected Xcode.", file=sys.stderr)
        subprocess.run(["xcodebuild", "-downloadPlatform", "iOS"], check=True, stdout=sys.stderr, timeout=900)
        data = inventory()
        runtimes = available_runtimes(data)
    if not runtimes:
        raise RuntimeError("No available iOS 17+ simulator runtime. Install an iOS runtime in Xcode, or use --install-runtime in CI.")

    iphone_types = {item["identifier"] for item in data.get("devicetypes", []) if item.get("productFamily") == "iPhone"}
    for runtime in runtimes:
        phones = [device for device in data.get("devices", {}).get(runtime["identifier"], [])
                  if device.get("isAvailable") and
                  (device.get("deviceTypeIdentifier") in iphone_types or device["name"].startswith("iPhone"))]
        if phones:
            phone = sorted(phones, key=lambda item: (item["name"] != PREFERRED_PHONE, item["name"], item["udid"]))[0]
            print(f"Using {phone['name']} / iOS {runtime['version']} ({phone['udid']})", file=sys.stderr)
            return f"platform=iOS Simulator,id={phone['udid']}"

    # A runner can have an installed runtime but no simulator devices at all.
    for runtime in runtimes:
        types = runtime.get("supportedDeviceTypes", [])
        phones = [item for item in types if item.get("productFamily") == "iPhone"]
        if not phones:
            continue
        phone = sorted(phones, key=lambda item: (item["name"] != PREFERRED_PHONE, item["name"]))[0]
        result = subprocess.run(
            ["xcrun", "simctl", "create", "Finances CI iPhone", phone["identifier"], runtime["identifier"]],
            check=True, capture_output=True, text=True,
        )
        identifier = result.stdout.strip()
        if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identifier):
            raise RuntimeError("simctl create did not return a simulator UDID")
        print(f"Created {phone['name']} / iOS {runtime['version']} ({identifier})", file=sys.stderr)
        return f"platform=iOS Simulator,id={identifier}"
    raise RuntimeError("The available iOS runtimes do not support an iPhone simulator.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-runtime", action="store_true", help="Download an iOS runtime only when none is available")
    arguments = parser.parse_args()
    try:
        print(prepare(allow_install=arguments.install_runtime))
        return 0
    except (RuntimeError, subprocess.SubprocessError, ValueError) as error:
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        print(f"Simulator preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
