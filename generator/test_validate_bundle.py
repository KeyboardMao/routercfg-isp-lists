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


class RouterOSVariablePolicyTests(unittest.TestCase):
    def test_scans_all_declaration_forms_and_semicolon_declarations(self) -> None:
        script = (
            ":local safeName 1; :local mode 2\n"
            ":global version 3\n"
            ":for n from=0 to=1 do={}\n"
            ":foreach ruleId in={} do={}\n"
            ":onerror script in={} do={}\n"
        )
        self.assertEqual(
            validate_bundle.routeros_reserved_variable_conflicts(script),
            ["mode", "n", "script", "version"],
        )

    def test_allows_project_specific_names(self) -> None:
        script = (
            ":local restoreMode 1; :local releaseToken 2\n"
            ":foreach bucketIndex in={} do={}\n"
            ":onerror updaterError in={} do={}\n"
        )
        self.assertEqual(
            validate_bundle.routeros_reserved_variable_conflicts(script), []
        )

    def test_rejects_unescaped_routeros_regex_end_anchor(self) -> None:
        bad = r':if (($value ~ "^[0-9]+$") = false) do={}'
        good = r':if (($value ~ "^[0-9]+\$") = false) do={}'
        self.assertTrue(
            validate_bundle.has_unescaped_routeros_regex_end_anchor(bad)
        )
        self.assertFalse(
            validate_bundle.has_unescaped_routeros_regex_end_anchor(good)
        )


if __name__ == "__main__":
    unittest.main()
