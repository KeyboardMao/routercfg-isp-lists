#!/usr/bin/env python3
"""Static checks for the deployment bundle and generated publication."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MINIMUM_ROUTEROS_VERSION = (7, 24, 4)
SUPPORTED_ROUTEROS_MAJOR = 7
SUPPORTED_ROUTEROS_CHANNELS = {"stable", "long-term"}
ROUTEROS_VERSION_RE = re.compile(
    r"^([0-9]+)\.([0-9]+)\.([0-9]+) \((stable|long-term)\)$"
)


def routeros_version_supported(value: str) -> bool:
    match = ROUTEROS_VERSION_RE.fullmatch(value)
    if match is None:
        return False
    major, minor, patch = (int(part) for part in match.groups()[:3])
    channel = match.group(4)
    return (
        major == SUPPORTED_ROUTEROS_MAJOR
        and (major, minor, patch) >= MINIMUM_ROUTEROS_VERSION
        and channel in SUPPORTED_ROUTEROS_CHANNELS
    )


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
    files = [
        routeros / "install-template.rsc",
        routeros / "remove-automation.rsc",
        routeros / "rollback-to-legacy-20260917.rsc",
    ]
    for path in files:
        if not path.is_file():
            raise ValueError(f"required RouterOS file is missing: {path}")
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
        "list counts are missing or non-numeric",
        "payload size is missing or non-numeric",
        "Reinstallation is the supported migration path",
    ):
        if required not in installer:
            raise ValueError(f"install template is missing required guard: {required}")
    if "/ip firewall mangle remove" in installer:
        raise ValueError("installer/updater must never remove mangle rules")
    if '[:pick [:tostr [/system resource get version]] 0 6]' in installer:
        raise ValueError("installer still contains the obsolete exact-version guard")

    block_pattern = re.compile(
        r"# ROUTEROS_COMPATIBILITY_POLICY_BEGIN\n(.*?)"
        r"# ROUTEROS_COMPATIBILITY_POLICY_END",
        re.DOTALL,
    )
    blocks = block_pattern.findall(installer)
    if len(blocks) != 2:
        raise ValueError("installer must contain two compatibility policy blocks")
    normalized_blocks = [
        "\n".join(line.strip() for line in block.splitlines() if line.strip())
        for block in blocks
    ]
    if normalized_blocks[0] != normalized_blocks[1]:
        raise ValueError("installer and updater compatibility policies differ")
    for required in (
        ':local minimumRouterVersion "7.24.4"',
        ":local supportedMajor 7",
        '"(stable)"',
        '"(long-term)"',
        "($routerMajor != $supportedMajor)",
    ):
        if required not in normalized_blocks[0]:
            raise ValueError(f"compatibility policy is missing: {required}")

    workflow = (ROOT / ".github" / "workflows" / "publish.yml").read_text(encoding="utf-8")
    if 'cron: "0 16 * * *"' not in workflow:
        raise ValueError("workflow must run at 00:00 Asia/Shanghai")
    for required in ('- "routeros/**"', '- "README.md"', "--max-filesize 4096"):
        if required not in workflow:
            raise ValueError(f"workflow is missing safety requirement: {required}")
    if "--output /tmp/previous-manifest.json || true" in workflow:
        raise ValueError("workflow must not bypass the production change gate")

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for obsolete in (
        "RouterOS 不再是7.24.4",
        "更新器故意锁定",
        "RouterOS 显示 ",
    ):
        if obsolete in readme:
            raise ValueError(f"README contains obsolete version guidance: {obsolete}")


def validate_public(path: Path) -> None:
    manifest_path = path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="ascii"))
    if manifest["schema"] != "routercfg.isp-affinity-lists":
        raise ValueError("published schema mismatch")
    if manifest["schema_version"] != 1:
        raise ValueError("published schema version mismatch")
    if manifest_path.stat().st_size > 4096:
        raise ValueError("manifest is too large for RouterOS variable processing")
    version = manifest["version"]
    if re.fullmatch(r"[0-9a-f]{16}", version) is None:
        raise ValueError("published release version is invalid")
    marker = manifest["marker"]
    if marker != f"routercfg-auto:{version}":
        raise ValueError("published release marker is invalid")
    if set(manifest["slots"]) != {"a", "b"}:
        raise ValueError("published slots must be exactly a and b")
    routeros = manifest["routeros"]
    if (
        routeros["minimum_version"] != "7.24.4"
        or routeros["supported_major"] != 7
        or set(routeros["supported_channels"]) != SUPPORTED_ROUTEROS_CHANNELS
    ):
        raise ValueError("published RouterOS compatibility metadata mismatch")
    if not (path / "index.html").is_file():
        raise ValueError("published index.html is missing")
    for slot in ("a", "b"):
        metadata = manifest["slots"][slot]
        if metadata["file"] != f"slot-{slot}.rsc":
            raise ValueError(f"slot {slot}: unexpected payload filename")
        payload_path = path / metadata["file"]
        payload = payload_path.read_bytes()
        if not 100_000 <= len(payload) <= 2_000_000:
            raise ValueError(f"slot {slot}: payload size outside updater limits")
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
