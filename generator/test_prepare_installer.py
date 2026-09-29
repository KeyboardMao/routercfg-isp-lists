from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import prepare_installer


class PrepareInstallerTests(unittest.TestCase):
    def test_valid_url(self) -> None:
        self.assertEqual(
            prepare_installer.validate_base_url("https://example.github.io/routeros-lists"),
            "https://example.github.io/routeros-lists",
        )

    def test_rejects_unsafe_or_ambiguous_urls(self) -> None:
        for value in (
            "http://example.test/lists",
            "https://user:pass@example.test/lists",
            "https://example.test/lists/",
            "https://example.test/lists?token=secret",
            "https://example.test:8443/lists",
            'https://example.test/li"sts',
            "https://example.test/li$sts",
            "https://example.test/li%20sts",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    prepare_installer.validate_base_url(value)

    def test_replaces_exactly_two_placeholders(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "template.rsc"
            output = root / "install.rsc"
            template.write_text(
                ':local a "BASE_URL_REPLACE_ME"\n:local b "BASE_URL_REPLACE_ME"\n',
                encoding="ascii",
            )
            prepare_installer.prepare(
                template,
                output,
                "https://example.github.io/routeros-lists",
            )
            rendered = output.read_text(encoding="ascii")
            self.assertNotIn("BASE_URL_REPLACE_ME", rendered)
            self.assertEqual(rendered.count("https://example.github.io/routeros-lists"), 2)


if __name__ == "__main__":
    unittest.main()
