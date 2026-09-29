#!/usr/bin/env python3
"""Static checks for the deployment bundle and generated publication."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def check_balanced_routeros(path: Path) -> None:
    text = path.read_text(encoding="ascii")
    stack: list[tuple[str, int]] = []
    pairs = {"}": "{", "]": "[", ")": "("}
    opening = set(pairs.values())
    in_string = False
    escaped = False
    in_comment = False
    line = 1
    for char in text:
        if char == "\n":
            line += 1
            in_comment = False
            escaped = False
            continue
        if in_comment:
            continue
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == "#":
            in_comment = True
        elif char == '"':
            in_string = True
        elif char in opening:
            stack.append((char, line))
        elif char in pairs:
            if not stack or stack[-1][0] != pairs[char]:
                raise ValueError(f"{path}: unmatched {char!r} on line {line}")
            stack.pop()
    if in_string:
        raise ValueError(f"{path}: unterminated string")
    if stack:
        char, opened_line = stack[-1]
        raise ValueError(f"{path}: unmatched {char!r} opened on line {opened_line}")


def validate_templates() -> None:
    routeros = ROOT / "routeros"
    files = sorted(routeros.glob("*.rsc"))
    if len(files) != 3:
        raise ValueError(f"expected exactly three RouterOS templates, found {len(files)}")
    for path in files:
        check_balanced_routeros(path)

    installer = (routeros / "install-template.rsc").read_text(encoding="ascii")
    if installer.count("BASE_URL_REPLACE_ME") != 2:
        raise ValueError("install template must contain exactly two base URL placeholders")
    for required in (
        "routercfg ISP affinity: ordinary Unicom-only destination",
        "routercfg ISP affinity: ordinary Mobile-only destination",
        "check-certificate=yes-without-crl",
        "policy=ftp,read,write,test,policy",
        "start-time=00:10:00",
        "active slot was preserved",
        "policy switch failed and was rolled back",
    ):
        if required not in installer:
            raise ValueError(f"install template is missing required guard: {required}")
    if "/ip firewall mangle remove" in installer:
        raise ValueError("installer/updater must never remove mangle rules")

    workflow = (ROOT / ".github" / "workflows" / "publish.yml").read_text(encoding="utf-8")
    if 'cron: "0 16 * * *"' not in workflow:
        raise ValueError("workflow must run at 00:00 Asia/Shanghai")


def validate_public(path: Path) -> None:
    manifest_path = path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="ascii"))
    if manifest["schema"] != "routercfg.isp-affinity-lists":
        raise ValueError("published schema mismatch")
    if manifest["schema_version"] != 1:
        raise ValueError("published schema version mismatch")
    if manifest_path.stat().st_size > 4096:
        raise ValueError("manifest is too large for RouterOS variable processing")
    marker = manifest["marker"]
    for slot in ("a", "b"):
        metadata = manifest["slots"][slot]
        payload_path = path / metadata["file"]
        payload = payload_path.read_bytes()
        if len(payload) != metadata["bytes"]:
            raise ValueError(f"slot {slot}: byte count mismatch")
        if hashlib.sha512(payload).hexdigest() != metadata["sha512"]:
            raise ValueError(f"slot {slot}: SHA-512 mismatch")
        check_balanced_routeros(payload_path)
        text = payload.decode("ascii")
        if text.count("/ip firewall address-list add list=$unicomList") != manifest["lists"]["unicom"]["count"]:
            raise ValueError(f"slot {slot}: Unicom command count mismatch")
        if text.count("/ip firewall address-list add list=$mobileList") != manifest["lists"]["mobile"]["count"]:
            raise ValueError(f"slot {slot}: Mobile command count mismatch")
        # Two metadata comments on real prefixes plus two post-import checks.
        if text.count(f'comment="{marker}"') != 4:
            raise ValueError(f"slot {slot}: release marker count mismatch")
        forbidden = (
            "/ip firewall mangle set",
            "/ip firewall mangle remove",
            "/ip firewall nat",
            "/ip firewall filter",
            "/routing",
            "/system",
        )
        for command in forbidden:
            if command in text:
                raise ValueError(f"slot {slot}: forbidden command {command!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--public", type=Path)
    args = parser.parse_args()
    validate_templates()
    if args.public is not None:
        validate_public(args.public)
    print("bundle validation passed")


if __name__ == "__main__":
    main()
