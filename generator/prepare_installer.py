#!/usr/bin/env python3
"""Prepare the RouterOS installer with one validated GitHub Pages base URL."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from urllib.parse import urlsplit


PLACEHOLDER = "BASE_URL_REPLACE_ME"
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEMPLATE = ROOT / "routeros" / "install-template.rsc"
DEFAULT_OUTPUT = ROOT / "routeros" / "install.rsc"
SAFE_BASE_URL_RE = re.compile(
    r"https://[A-Za-z0-9.-]+(?::443)?(?:/[A-Za-z0-9._~-]+)*"
)


def validate_base_url(value: str) -> str:
    if value != value.strip():
        raise ValueError("base URL has leading or trailing whitespace")
    if value.endswith("/"):
        raise ValueError("base URL must not end with a slash")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("base URL must be an absolute HTTPS URL")
    if parsed.username or parsed.password:
        raise ValueError("base URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("base URL must not contain a query or fragment")
    if parsed.port not in (None, 443):
        raise ValueError("base URL must use the default HTTPS port")
    if SAFE_BASE_URL_RE.fullmatch(value) is None:
        raise ValueError("base URL contains characters unsafe for a RouterOS string")
    return value


def prepare(template: Path, output: Path, base_url: str) -> None:
    validated = validate_base_url(base_url)
    text = template.read_text(encoding="ascii")
    if text.count(PLACEHOLDER) != 2:
        raise ValueError("installer template does not contain exactly two placeholders")
    rendered = text.replace(PLACEHOLDER, validated)
    if PLACEHOLDER in rendered or rendered.count(validated) < 2:
        raise ValueError("installer URL replacement post-check failed")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="ascii", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    prepare(args.template, args.output, args.base_url)
    print(f"prepared installer: {args.output}")


if __name__ == "__main__":
    main()
