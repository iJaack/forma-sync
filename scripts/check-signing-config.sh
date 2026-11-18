#!/bin/bash
# Offline checks only: unsigned simulator builds, no physical devices or signing.
set -euo pipefail
cd "$(dirname "$0")/.."

local_config=Config/Local.xcconfig
mode=default
if [[ $# == 1 && "$1" == --local ]]; then
    mode=local
elif [[ $# != 0 ]]; then
    echo "Usage: bash scripts/check-signing-config.sh [--local]" >&2
    exit 1
fi

if [[ "$mode" == default && ( -e "$local_config" || -L "$local_config" ) ]]; then
    echo "Default check requires no Config/Local.xcconfig; use --local to verify your existing file." >&2
    exit 1
elif [[ "$mode" == local && ! -f "$local_config" ]]; then
    echo "--local requires an existing Config/Local.xcconfig; it will not be created or changed." >&2
    exit 1
fi

created_local=0
cleanup() {
    if [[ "$created_local" == 1 ]]; then
        rm -f "$local_config"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

logs=build/self-install
mkdir -p "$logs"
if ! xcodegen generate > "$logs/generate.log" 2>&1; then
    echo "FAIL: project generation." >&2
    exit 1
fi

check_configuration() {
    local label="$1" configuration settings
    for configuration in Debug Release; do
        settings="$logs/$label-$configuration-settings.json"
        if ! xcodebuild -project FormaSync.xcodeproj -alltargets -configuration "$configuration" \
            -sdk iphonesimulator -showBuildSettings -json \
            -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO \
            > "$settings" 2> "$logs/$label-$configuration-settings.log"; then
            echo "FAIL: build settings ($label, $configuration)." >&2
            return 1
        fi
    done

    if ! xcodebuild -project FormaSync.xcodeproj -scheme FormaSync -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$logs/DerivedData" \
        -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build \
        > "$logs/$label-build.log" 2>&1; then
        echo "FAIL: unsigned simulator build ($label)." >&2
        return 1
    fi
    # Only the non-secret identifiers below are printed, including on assertion failures.
    python3 - "$logs" "$label" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import sys

logs, label = Path(sys.argv[1]), sys.argv[2]

def require(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)

expectations = {
    "EXPECT_TEAM": "DEVELOPMENT_TEAM",
    "EXPECT_BUNDLE_ID": "FORMA_BUNDLE_ID",
    "EXPECT_LEGACY_URL": "FORMA_LEGACY_INGEST_URL",
    "EXPECT_SLEEP_SOURCES": "FORMA_EXTRA_SLEEP_SOURCES",
    "EXPECT_KEYCHAIN_SERVICE": "FORMA_KEYCHAIN_SERVICE",
}
resolved = {}
for configuration in ("Debug", "Release"):
    with (logs / f"{label}-{configuration}-settings.json").open() as stream:
        targets = {item["target"]: item["buildSettings"] for item in json.load(stream)}
    require(set(targets) == {"FormaSync", "FormaSyncTests", "FormaSyncUITests"}, "target list")
    app = targets["FormaSync"]
    bundle = app["PRODUCT_BUNDLE_IDENTIFIER"]
    for name, suffix in (("FormaSync", ""), ("FormaSyncTests", ".tests"), ("FormaSyncUITests", ".uitests")):
        settings = targets[name]
        for env, key in expectations.items():
            # Xcode may omit build settings whose resolved value is empty.
            if env in os.environ:
                require(settings.get(key, "") == os.environ[env], f"{configuration}/{name}: {key}")
        require(settings["PRODUCT_BUNDLE_IDENTIFIER"] == bundle + suffix, f"{name}: bundle identifier")
        require(settings["FORMA_BUNDLE_ID"] == bundle, f"{name}: FORMA_BUNDLE_ID")
        require(settings.get("CODE_SIGN_STYLE") == "Automatic", f"{name}: signing style")
        require(settings.get("CODE_SIGNING_ALLOWED") == "NO", f"{name}: signing must be disabled")
        require(settings.get("CURRENT_PROJECT_VERSION") == "5", f"{name}: build version")
        require(settings.get("MARKETING_VERSION") == "2.1.1", f"{name}: app version")
    require(app.get("CODE_SIGN_ENTITLEMENTS") == "FormaSync/FormaSync.entitlements", "HealthKit entitlements")
    if "EXPECT_REFRESH_ID" in os.environ:
        require(bundle + ".refresh" == os.environ["EXPECT_REFRESH_ID"], f"{configuration}: refresh identifier")
    resolved[configuration] = app

with (logs / "DerivedData/Build/Products/Debug-iphonesimulator/FormaSync.app/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
app = resolved["Debug"]
bundle = app["PRODUCT_BUNDLE_IDENTIFIER"]
for plist_key, setting in (
    ("FormaLegacyIngestURL", "FORMA_LEGACY_INGEST_URL"),
    ("FormaExtraSleepSources", "FORMA_EXTRA_SLEEP_SOURCES"),
    ("FormaKeychainService", "FORMA_KEYCHAIN_SERVICE"),
):
    require(info.get(plist_key) == app.get(setting, ""), f"Info.plist: {plist_key}")
require(info.get("CFBundleIdentifier") == bundle, "Info.plist: bundle identifier")
require(info.get("BGTaskSchedulerPermittedIdentifiers") == [bundle + ".refresh"], "Info.plist: refresh identifier")
require(info.get("CFBundleVersion") == "5", "Info.plist: build version")
require(info.get("CFBundleShortVersionString") == "2.1.1", "Info.plist: app version")
print(f"PASS {label}: Debug/Release settings and unsigned simulator Info.plist")
for key in expectations.values():
    print(f"  {key}={app.get(key, '')}")
print(f"  REFRESH_ID={bundle}.refresh")
PY
}

if [[ "$mode" == local ]]; then
    check_configuration local
else
    EXPECT_TEAM='' EXPECT_BUNDLE_ID=com.example.formasync \
        EXPECT_LEGACY_URL='' EXPECT_SLEEP_SOURCES='' \
        EXPECT_KEYCHAIN_SERVICE=com.example.formasync.ingest \
        EXPECT_REFRESH_ID=com.example.formasync.refresh check_configuration default

    # noclobber protects a file created by another process after the initial check.
    (set -o noclobber; printf '%s\n' 'DEVELOPMENT_TEAM = ZZZZZZZZZZ' \
        'FORMA_BUNDLE_ID = com.example.override' \
        'FORMA_LEGACY_INGEST_URL = https:/$()/override.example/api/ingest/health' \
        'FORMA_EXTRA_SLEEP_SOURCES = com.example.sleep' > "$local_config")
    created_local=1
    EXPECT_TEAM=ZZZZZZZZZZ EXPECT_BUNDLE_ID=com.example.override \
        EXPECT_LEGACY_URL=https://override.example/api/ingest/health \
        EXPECT_SLEEP_SOURCES=com.example.sleep EXPECT_KEYCHAIN_SERVICE=com.example.override.ingest \
        EXPECT_REFRESH_ID=com.example.override.refresh check_configuration override
    cleanup
    created_local=0
    echo "PASS: temporary Config/Local.xcconfig removed."
fi
