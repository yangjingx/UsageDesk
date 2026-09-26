#!/usr/bin/env python3
"""Build the public, arm64 UsageDesk app and release ZIP from this checkout."""

from pathlib import Path
import atexit
import os
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work" / "release"
BUILD = Path(tempfile.mkdtemp(prefix="usagedesk-build-", dir="/private/tmp"))
atexit.register(shutil.rmtree, BUILD, ignore_errors=True)
APP = BUILD / "UsageDesk.app"
CONTENTS = APP / "Contents"
RESOURCES = CONTENTS / "Resources"
MACOS = CONTENTS / "MacOS"
ICONSET = BUILD / "UsageDesk.iconset"
ZIP = OUT / "UsageDesk.zip"


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def icon_chunk(kind, filename):
    data = (ICONSET / filename).read_bytes()
    return kind.encode("ascii") + (len(data) + 8).to_bytes(4, "big") + data


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    default_sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    compatible_sdks = sorted(Path(default_sdk).parent.glob("MacOSX26.*.sdk"))
    sdk = os.environ.get("USAGEDESK_SDK") or str(
        compatible_sdks[-1] if compatible_sdks else default_sdk
    )
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    if APP.exists():
        shutil.rmtree(APP)
    MACOS.mkdir(parents=True)
    RESOURCES.mkdir()
    ICONSET.mkdir(parents=True, exist_ok=True)

    info = {
        "CFBundleIdentifier": "com.local.usagedesk",
        "CFBundleName": "UsageDesk",
        "CFBundleDisplayName": "UsageDesk",
        "CFBundleExecutable": "UsageDesk",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "7",
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "UsageDesk.icns",
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }
    with (CONTENTS / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)

    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(OUT / "clang-cache")
    environment["SWIFT_MODULE_CACHE_PATH"] = str(OUT / "swift-cache")
    sources = [ROOT / name for name in (
        "Appearance.swift", "AppPreferences.swift", "DeepSeek.swift",
        "UsageDesk.swift", "main.swift"
    )]
    run(compiler, "-O", "-sdk", sdk, "-target", "arm64-apple-macos15.0",
        "-o", str(MACOS / "UsageDesk"), *map(str, sources), env=environment)

    for source, target in (
        (ROOT / "assets/deepseek-mark.png", "deepseek-mark.png"),
        (ROOT / "UsageDesk-icon.png", "UsageDesk-icon-light.png"),
        (ROOT / "assets/UsageDesk-icon-dark.png", "UsageDesk-icon-dark.png"),
    ):
        shutil.copy2(source, RESOURCES / target)

    icon_parts = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            filename = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
            run("sips", "-z", str(points * scale), str(points * scale),
                str(ROOT / "UsageDesk-icon.png"), "--out", str(ICONSET / filename),
                stdout=subprocess.DEVNULL)
    for kind, filename in (
        ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
    ):
        icon_parts.append(icon_chunk(kind, filename))
    payload = b"".join(icon_parts)
    (RESOURCES / "UsageDesk.icns").write_bytes(
        b"icns" + (len(payload) + 8).to_bytes(4, "big") + payload
    )

    run("xattr", "-cr", str(APP))
    run("codesign", "--force", "--sign", "-", "--identifier",
        "com.local.usagedesk", str(APP))
    run("codesign", "--verify", "--strict", str(APP))
    if ZIP.exists():
        ZIP.unlink()
    archive_env = os.environ.copy()
    archive_env["DITTONORSRC"] = "1"
    run("ditto", "-c", "-k", "--keepParent", str(APP), str(ZIP), env=archive_env)
    extracted = BUILD / "extracted"
    extracted.mkdir()
    run("ditto", "-x", "-k", str(ZIP), str(extracted), env=archive_env)
    run("codesign", "--verify", "--strict", str(extracted / "UsageDesk.app"))
    print(ZIP)


if __name__ == "__main__":
    main()
