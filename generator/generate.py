#!/usr/bin/env python3
"""Build validated, disjoint RouterOS ISP address-list payloads.

The generated slot payloads only remove and populate their own dedicated
address-list names.  They refuse to run while that slot is referenced by a
mangle rule.  The RouterOS updater imports the inactive slot, validates it,
and switches the two exact policy rules afterwards.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


SCHEMA = "routercfg.isp-affinity-lists"
SCHEMA_VERSION = 1
DEFAULT_UNICOM_URL = "https://gaoyifan.github.io/china-operator-ip/unicom.txt"
DEFAULT_MOBILE_URL = "https://gaoyifan.github.io/china-operator-ip/cmcc.txt"
SOURCE_PROJECT = "https://github.com/gaoyifan/china-operator-ip/tree/ip-lists"
USER_AGENT = "routercfg-isp-list-builder/1"

LIST_NAMES = {
    "a": {
        "unicom": "routercfg-isp-unicom-auto-a",
        "mobile": "routercfg-isp-mobile-auto-a",
    },
    "b": {
        "unicom": "routercfg-isp-unicom-auto-b",
        "mobile": "routercfg-isp-mobile-auto-b",
    },
}

# These are deliberately broad hard stops, not expected exact values.  Exact
# counts are carried in the signed-by-TLS manifest and checked again on-router.
RAW_COUNT_BOUNDS = {"unicom": (800, 5000), "mobile": (500, 4000)}
OUTPUT_COUNT_BOUNDS = {"unicom": (500, 5000), "mobile": (300, 4000)}
OUTPUT_ADDRESS_BOUNDS = {
    "unicom": (20_000_000, 200_000_000),
    "mobile": (10_000_000, 150_000_000),
}
MAX_OUTPUT_BYTES = 2_000_000
MAX_MANIFEST_BYTES = 4096


@dataclass(frozen=True)
class SourceData:
    name: str
    origin: str
    raw: bytes
    networks: tuple[ipaddress.IPv4Network, ...]
    sha256: str


def _read_url(url: str, attempts: int = 4) -> bytes:
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "text/plain"},
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                if response.status != 200:
                    raise RuntimeError(f"HTTP {response.status} for {url}")
                content_type = response.headers.get_content_type()
                if content_type not in {"text/plain", "application/octet-stream"}:
                    raise RuntimeError(
                        f"unexpected Content-Type {content_type!r} for {url}"
                    )
                data = response.read(2_000_001)
                if len(data) > 2_000_000:
                    raise RuntimeError(f"source is unexpectedly large: {url}")
                return data
        except (OSError, RuntimeError, urllib.error.URLError) as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(2 ** (attempt - 1))
    raise RuntimeError(f"failed to download {url}: {last_error}")


def _read_source(path: Path | None, url: str) -> tuple[bytes, str]:
    if path is not None:
        return path.read_bytes(), str(path)
    return _read_url(url), url


def parse_source(name: str, raw: bytes, origin: str) -> SourceData:
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{name}: source is not ASCII") from exc

    networks: list[ipaddress.IPv4Network] = []
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        value = raw_line.strip()
        if not value or value.startswith("#"):
            continue
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ValueError(f"{name}:{line_number}: invalid CIDR {value!r}: {exc}") from exc
        if not isinstance(network, ipaddress.IPv4Network):
            raise ValueError(f"{name}:{line_number}: IPv6 entry is not allowed: {network}")
        if not network.network_address.is_global or not network.broadcast_address.is_global:
            raise ValueError(f"{name}:{line_number}: non-global IPv4 range: {network}")
        networks.append(network)

    low, high = RAW_COUNT_BOUNDS[name]
    if not low <= len(networks) <= high:
        raise ValueError(
            f"{name}: raw prefix count {len(networks)} outside safety range {low}..{high}"
        )

    canonical = tuple(ipaddress.collapse_addresses(networks))
    return SourceData(
        name=name,
        origin=origin,
        raw=raw,
        networks=canonical,
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def to_intervals(
    networks: Iterable[ipaddress.IPv4Network],
) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for start, end in sorted(
        (int(network.network_address), int(network.broadcast_address))
        for network in networks
    ):
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def subtract_intervals(
    left: list[tuple[int, int]], right: list[tuple[int, int]]
) -> list[tuple[int, int]]:
    answer: list[tuple[int, int]] = []
    right_index = 0
    for left_start, left_end in left:
        cursor = left_start
        while right_index < len(right) and right[right_index][1] < cursor:
            right_index += 1
        scan = right_index
        while scan < len(right) and right[scan][0] <= left_end:
            right_start, right_end = right[scan]
            if right_start > cursor:
                answer.append((cursor, right_start - 1))
            cursor = max(cursor, right_end + 1)
            if cursor > left_end:
                break
            scan += 1
        if cursor <= left_end:
            answer.append((cursor, left_end))
    return answer


def intervals_to_networks(
    ranges: Iterable[tuple[int, int]],
) -> tuple[ipaddress.IPv4Network, ...]:
    return tuple(
        network
        for start, end in ranges
        for network in ipaddress.summarize_address_range(
            ipaddress.IPv4Address(start), ipaddress.IPv4Address(end)
        )
    )


def ensure_disjoint(
    unicom: tuple[ipaddress.IPv4Network, ...],
    mobile: tuple[ipaddress.IPv4Network, ...],
) -> None:
    unicom_ranges = to_intervals(unicom)
    mobile_ranges = to_intervals(mobile)
    i = 0
    j = 0
    while i < len(unicom_ranges) and j < len(mobile_ranges):
        u_start, u_end = unicom_ranges[i]
        m_start, m_end = mobile_ranges[j]
        if u_end < m_start:
            i += 1
        elif m_end < u_start:
            j += 1
        else:
            raise ValueError(
                "generated lists overlap at "
                f"{ipaddress.IPv4Address(max(u_start, m_start))}"
            )


def total_addresses(networks: Iterable[ipaddress.IPv4Network]) -> int:
    return sum(network.num_addresses for network in networks)


def build_release_version(
    unicom: tuple[ipaddress.IPv4Network, ...],
    mobile: tuple[ipaddress.IPv4Network, ...],
) -> str:
    """Identify the effective published lists, independent of source formatting."""
    digest = hashlib.sha256()
    digest.update(f"{SCHEMA}\n{SCHEMA_VERSION}\nunicom\n".encode("ascii"))
    for network in unicom:
        digest.update(f"{network}\n".encode("ascii"))
    digest.update(b"mobile\n")
    for network in mobile:
        digest.update(f"{network}\n".encode("ascii"))
    return digest.hexdigest()[:16]


def validate_output(name: str, networks: tuple[ipaddress.IPv4Network, ...]) -> None:
    low, high = OUTPUT_COUNT_BOUNDS[name]
    if not low <= len(networks) <= high:
        raise ValueError(
            f"{name}: generated count {len(networks)} outside safety range {low}..{high}"
        )
    address_low, address_high = OUTPUT_ADDRESS_BOUNDS[name]
    address_count = total_addresses(networks)
    if not address_low <= address_count <= address_high:
        raise ValueError(
            f"{name}: generated address coverage {address_count} outside safety range "
            f"{address_low}..{address_high}"
        )


def load_previous_manifest(path: Path | None) -> dict | None:
    if path is None or not path.exists() or path.stat().st_size == 0:
        return None
    if path.stat().st_size > MAX_MANIFEST_BYTES:
        raise ValueError(f"previous manifest is too large: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema") != SCHEMA or data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"previous manifest has an unexpected schema: {path}")
    return data


def enforce_change_limit(
    previous: dict | None,
    new_metrics: dict[str, dict[str, int]],
    max_ratio: float,
    allow_large_change: bool,
) -> None:
    if previous is None or allow_large_change:
        return
    for name in ("unicom", "mobile"):
        for metric in ("count", "addresses"):
            old = int(previous["lists"][name][metric])
            new = new_metrics[name][metric]
            if old <= 0:
                raise ValueError(f"previous {name} {metric} is invalid: {old}")
            ratio = abs(new - old) / old
            if ratio > max_ratio:
                raise ValueError(
                    f"{name} {metric} changed from {old} to {new} ({ratio:.1%}); "
                    f"limit is {max_ratio:.1%}. Review upstream and run a manual "
                    "workflow with allow_large_change=true if the change is legitimate."
                )


def quote_routeros(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build_slot_payload(
    slot: str,
    version: str,
    marker: str,
    unicom: tuple[ipaddress.IPv4Network, ...],
    mobile: tuple[ipaddress.IPv4Network, ...],
    source_unicom: SourceData,
    source_mobile: SourceData,
) -> bytes:
    names = LIST_NAMES[slot]
    label = slot.upper()
    lines = [
        f"# {SCHEMA} v{SCHEMA_VERSION}; slot={label}; version={version}",
        f"# Source: {SOURCE_PROJECT}",
        f"# unicom SHA256={source_unicom.sha256}; normalized={len(source_unicom.networks)}",
        f"# cmcc SHA256={source_mobile.sha256}; normalized={len(source_mobile.networks)}",
        "# Generated data only. This file does not change routes, NAT, filters, or schedulers.",
        "{",
        f'    :local unicomList {quote_routeros(names["unicom"])}',
        f'    :local mobileList {quote_routeros(names["mobile"])}',
        "    :if ([/ip firewall mangle print count-only as-value where dst-address-list=$unicomList] != 0) do={ :error \"ISP auto payload: Unicom target slot is active\" }",
        "    :if ([/ip firewall mangle print count-only as-value where dst-address-list=$mobileList] != 0) do={ :error \"ISP auto payload: Mobile target slot is active\" }",
        "    /ip firewall address-list remove [find where list=$unicomList]",
        "    /ip firewall address-list remove [find where list=$mobileList]",
        "",
        f"    # Unicom-only destinations ({len(unicom)} prefixes).",
    ]
    for index, network in enumerate(unicom):
        comment = f" comment={quote_routeros(marker)}" if index == 0 else ""
        lines.append(
            f"    /ip firewall address-list add list=$unicomList address={network}{comment}"
        )
    lines.append("")
    lines.append(f"    # Mobile-only destinations ({len(mobile)} prefixes).")
    for index, network in enumerate(mobile):
        comment = f" comment={quote_routeros(marker)}" if index == 0 else ""
        lines.append(
            f"    /ip firewall address-list add list=$mobileList address={network}{comment}"
        )
    lines.extend(
        [
            "",
            f"    :if ([/ip firewall address-list print count-only as-value where list=$unicomList] != {len(unicom)}) do={{ :error \"ISP auto payload: Unicom count mismatch\" }}",
            f"    :if ([/ip firewall address-list print count-only as-value where list=$mobileList] != {len(mobile)}) do={{ :error \"ISP auto payload: Mobile count mismatch\" }}",
            f"    :if ([/ip firewall address-list print count-only as-value where list=$unicomList and comment={quote_routeros(marker)}] != 1) do={{ :error \"ISP auto payload: Unicom marker mismatch\" }}",
            f"    :if ([/ip firewall address-list print count-only as-value where list=$mobileList and comment={quote_routeros(marker)}] != 1) do={{ :error \"ISP auto payload: Mobile marker mismatch\" }}",
            f"    :put \"ISP auto payload {label} ready: version={version} Unicom={len(unicom)} Mobile={len(mobile)}\"",
            "}",
            "",
        ]
    )
    payload = "\n".join(lines).encode("ascii")
    if len(payload) > MAX_OUTPUT_BYTES:
        raise ValueError(f"slot {slot} payload is unexpectedly large: {len(payload)} bytes")
    return payload


def write_index(output: Path, manifest: dict) -> None:
    text = f"""<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>RouterOS ISP list feed</title></head>
<body>
<h1>RouterOS ISP list feed</h1>
<p>Version: <code>{manifest['version']}</code></p>
<p>Generated: <code>{manifest['generated_at']}</code></p>
<ul>
  <li>Unicom-only: {manifest['lists']['unicom']['count']} prefixes</li>
  <li>Mobile-only: {manifest['lists']['mobile']['count']} prefixes</li>
</ul>
<p><a href="manifest.json">manifest.json</a></p>
</body>
</html>
"""
    (output / "index.html").write_text(text, encoding="utf-8", newline="\n")


def build(args: argparse.Namespace) -> dict:
    unicom_raw, unicom_origin = _read_source(args.unicom_file, args.unicom_url)
    mobile_raw, mobile_origin = _read_source(args.mobile_file, args.mobile_url)
    unicom_source = parse_source("unicom", unicom_raw, unicom_origin)
    mobile_source = parse_source("mobile", mobile_raw, mobile_origin)

    unicom_ranges = to_intervals(unicom_source.networks)
    mobile_ranges = to_intervals(mobile_source.networks)
    unicom_only = intervals_to_networks(subtract_intervals(unicom_ranges, mobile_ranges))
    mobile_only = intervals_to_networks(subtract_intervals(mobile_ranges, unicom_ranges))
    validate_output("unicom", unicom_only)
    validate_output("mobile", mobile_only)
    ensure_disjoint(unicom_only, mobile_only)

    metrics = {
        "unicom": {"count": len(unicom_only), "addresses": total_addresses(unicom_only)},
        "mobile": {"count": len(mobile_only), "addresses": total_addresses(mobile_only)},
    }
    previous = load_previous_manifest(args.previous_manifest)
    enforce_change_limit(
        previous, metrics, args.max_count_change, args.allow_large_change
    )

    version = build_release_version(unicom_only, mobile_only)
    marker = f"routercfg-auto:{version}"

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    slot_metadata: dict[str, dict[str, str | int]] = {}
    for slot in ("a", "b"):
        payload = build_slot_payload(
            slot,
            version,
            marker,
            unicom_only,
            mobile_only,
            unicom_source,
            mobile_source,
        )
        filename = f"slot-{slot}.rsc"
        (output / filename).write_bytes(payload)
        slot_metadata[slot] = {
            "file": filename,
            "bytes": len(payload),
            "sha512": hashlib.sha512(payload).hexdigest(),
        }

    manifest = {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "version": version,
        "marker": marker,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "source_project": SOURCE_PROJECT,
        "sources": {
            "unicom": {
                "origin": unicom_source.origin,
                "sha256": unicom_source.sha256,
                "normalized_count": len(unicom_source.networks),
            },
            "mobile": {
                "origin": mobile_source.origin,
                "sha256": mobile_source.sha256,
                "normalized_count": len(mobile_source.networks),
            },
        },
        "lists": {
            "unicom": {
                "count": metrics["unicom"]["count"],
                "addresses": metrics["unicom"]["addresses"],
            },
            "mobile": {
                "count": metrics["mobile"]["count"],
                "addresses": metrics["mobile"]["addresses"],
            },
        },
        "slots": slot_metadata,
        "routeros": {
            "minimum_version": "7.24.4",
            "supported_major": 7,
            "supported_channels": ["stable", "long-term"],
            "unicom_rule_comment": "routercfg ISP affinity: ordinary Unicom-only destination",
            "mobile_rule_comment": "routercfg ISP affinity: ordinary Mobile-only destination",
        },
    }
    manifest_bytes = (
        json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("ascii")
    if len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise ValueError(f"manifest exceeds RouterOS safe variable size: {len(manifest_bytes)}")
    (output / "manifest.json").write_bytes(manifest_bytes)
    write_index(output, manifest)
    return manifest


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("public"))
    parser.add_argument("--unicom-url", default=DEFAULT_UNICOM_URL)
    parser.add_argument("--mobile-url", default=DEFAULT_MOBILE_URL)
    parser.add_argument("--unicom-file", type=Path)
    parser.add_argument("--mobile-file", type=Path)
    parser.add_argument("--previous-manifest", type=Path)
    parser.add_argument("--max-count-change", type=float, default=0.25)
    parser.add_argument("--allow-large-change", action="store_true")
    args = parser.parse_args(argv)
    if not 0 <= args.max_count_change <= 1:
        parser.error("--max-count-change must be between 0 and 1")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        manifest = build(parse_args(argv))
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(
        f"version={manifest['version']} "
        f"unicom={manifest['lists']['unicom']['count']} "
        f"mobile={manifest['lists']['mobile']['count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
