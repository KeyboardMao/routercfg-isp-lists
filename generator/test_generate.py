from __future__ import annotations

import ipaddress
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import generate


class GeneratorTests(unittest.TestCase):
    def test_subtraction_removes_overlap_from_both_sides(self) -> None:
        unicom = [ipaddress.IPv4Network("8.8.8.0/24"), ipaddress.IPv4Network("9.9.9.0/24")]
        mobile = [ipaddress.IPv4Network("8.8.8.128/25"), ipaddress.IPv4Network("11.0.0.0/24")]
        u_ranges = generate.to_intervals(unicom)
        m_ranges = generate.to_intervals(mobile)
        u_only = generate.intervals_to_networks(generate.subtract_intervals(u_ranges, m_ranges))
        m_only = generate.intervals_to_networks(generate.subtract_intervals(m_ranges, u_ranges))
        self.assertEqual(
            u_only,
            (ipaddress.IPv4Network("8.8.8.0/25"), ipaddress.IPv4Network("9.9.9.0/24")),
        )
        self.assertEqual(m_only, (ipaddress.IPv4Network("11.0.0.0/24"),))
        generate.ensure_disjoint(u_only, m_only)

    def test_parse_rejects_non_global_network(self) -> None:
        with mock.patch.dict(generate.RAW_COUNT_BOUNDS, {"unicom": (1, 10)}):
            with self.assertRaisesRegex(ValueError, "non-global"):
                generate.parse_source("unicom", b"192.168.0.0/16\n", "fixture")

    def test_payload_refuses_active_slot_and_contains_marker(self) -> None:
        source = generate.SourceData(
            name="unicom",
            origin="fixture",
            raw=b"8.8.8.0/24\n",
            networks=(ipaddress.IPv4Network("8.8.8.0/24"),),
            sha256="a" * 64,
        )
        payload = generate.build_slot_payload(
            "a",
            "0123456789abcdef",
            "routercfg-auto:0123456789abcdef",
            (ipaddress.IPv4Network("8.8.8.0/24"),),
            (ipaddress.IPv4Network("11.0.0.0/24"),),
            source,
            source,
        ).decode("ascii")
        self.assertIn("target slot is active", payload)
        self.assertIn('comment="routercfg-auto:0123456789abcdef"', payload)
        self.assertIn("routercfg-isp-unicom-auto-a", payload)

    def test_previous_manifest_change_gate(self) -> None:
        previous = {
            "schema": generate.SCHEMA,
            "schema_version": generate.SCHEMA_VERSION,
            "lists": {
                "unicom": {"count": 1000, "addresses": 50_000_000},
                "mobile": {"count": 1000, "addresses": 50_000_000},
            },
        }
        with self.assertRaisesRegex(ValueError, "changed"):
            generate.enforce_change_limit(
                previous,
                {
                    "unicom": {"count": 1400, "addresses": 50_000_000},
                    "mobile": {"count": 1000, "addresses": 50_000_000},
                },
                max_ratio=0.25,
                allow_large_change=False,
            )
        generate.enforce_change_limit(
            previous,
            {
                "unicom": {"count": 1400, "addresses": 50_000_000},
                "mobile": {"count": 1000, "addresses": 50_000_000},
            },
            max_ratio=0.25,
            allow_large_change=True,
        )

    def test_manifest_loader_rejects_wrong_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"schema": "wrong", "schema_version": 1}))
            with self.assertRaisesRegex(ValueError, "unexpected schema"):
                generate.load_previous_manifest(path)


if __name__ == "__main__":
    unittest.main()
