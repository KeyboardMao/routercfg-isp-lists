from __future__ import annotations

import unittest

import validate_bundle


class RouterOSVersionPolicyTests(unittest.TestCase):
    def test_supported_stable_v7_versions(self) -> None:
        for value in (
            "7.24.4 (stable)",
            "7.24.4 (long-term)",
            "7.24.10 (stable)",
            "7.25.0 (stable)",
            "7.99.99 (long-term)",
        ):
            with self.subTest(value=value):
                self.assertTrue(validate_bundle.routeros_version_supported(value))

    def test_unsupported_versions_fail_closed(self) -> None:
        for value in (
            "7.24.3 (stable)",
            "7.25.0 (testing)",
            "7.25rc1 (testing)",
            "6.49.18 (long-term)",
            "8.0.0 (stable)",
            "7.25.0",
            "unexpected",
        ):
            with self.subTest(value=value):
                self.assertFalse(validate_bundle.routeros_version_supported(value))


if __name__ == "__main__":
    unittest.main()
