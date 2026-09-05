#!/usr/bin/env python3
"""Generate portable colors from the exact bundled native catalog, offline.

Usage: python3 scripts/generate-portable-themes.py [--check]
Fails on unsupported Swift declarations instead of silently omitting themes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Vendor/GhosttyKit/Sources/GhosttyTheme"
OUTPUT = ROOT / "shared/terminal-themes.json"
LICENSE = ROOT / "desktop/public/themes/LICENSE.txt"
RECORD = ROOT / "shared/terminal-themes-source.json"
DECLARATION = re.compile(r"static let (\w+) = GhosttyThemeDefinition\(\s*(.*?)\n    \)", re.S)
STRING = r'"((?:[^"\\]|\\.)*)"'


def generate():
    definitions = {}
    source_files = sorted((SOURCE / "Themes").glob("Themes_*.swift"))
    source_files.append(SOURCE / "Themes/ThemeCatalog_Generated.swift")
    for source in source_files[:-1]:
        text = source.read_text()
        matches = list(DECLARATION.finditer(text))
        if len(matches) != text.count("= GhosttyThemeDefinition("):
            raise ValueError(f"Unparsed declaration in {source}")
        for match in matches:
            identifier, body = match.groups()
            fields = {key: json.loads('"' + raw + '"') for key, raw in re.findall(r"(\w+): " + STRING, body)}
            palette_match = re.search(r"palette: \[(.*?)\]", body, re.S)
            if not palette_match:
                raise ValueError(f"No palette in {identifier}")
            palette = {str(int(index)): "#" + value.lower() for index, value in re.findall(r'(\d+): "([a-fA-F0-9]{6})"', palette_match[1])}
            if set(palette) != {str(index) for index in range(16)}:
                raise ValueError(f"Incomplete ANSI palette in {identifier}")
            theme = {"name": fields["name"], "source": "bundled", "palette": palette, "skipped": []}
            for native, portable in [("background", "background"), ("foreground", "foreground"), ("cursorColor", "cursor"), ("selectionBackground", "selectionBackground")]:
                value = fields.get(native)
                if value is not None and not re.fullmatch(r"[a-fA-F0-9]{6}", value):
                    raise ValueError(f"Invalid color {native} in {identifier}")
                theme[portable] = "#" + value.lower() if value else None
            if identifier in definitions:
                raise ValueError(f"Duplicate definition {identifier}")
            definitions[identifier] = theme
    order = re.findall(r"^        \.(\w+),$", source_files[-1].read_text(), re.M)
    if set(order) != set(definitions) or len(order) != len(definitions):
        raise ValueError("Native catalog order and declarations do not match")
    themes = [definitions[identifier] for identifier in order]
    if len({theme["name"].casefold() for theme in themes}) != len(themes):
        raise ValueError("Catalog contains ambiguous theme names")
    license_source = SOURCE / "LICENSE"
    record = {
        "generator": "scripts/generate-portable-themes.py",
        "source": "Vendor/GhosttyKit/Sources/GhosttyTheme",
        "upstream": "https://github.com/mbadolato/iTerm2-Color-Schemes",
        "license": "MIT",
        "themeCount": len(themes),
        "hashEncoding": "UTF-8 with LF line endings",
        "files": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_text().encode("utf-8")).hexdigest() for path in [*source_files, license_source]},
    }
    return {
        OUTPUT: json.dumps(themes, ensure_ascii=False, indent=2) + "\n",
        LICENSE: license_source.read_text(),
        RECORD: json.dumps(record, ensure_ascii=False, indent=2) + "\n",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for path, text in generate().items():
        if args.check:
            if not path.exists() or path.read_text() != text:
                print(f"Stale generated file: {path.relative_to(ROOT)}", file=sys.stderr)
                return 1
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    print("Portable theme catalog matches the native source." if args.check else "Generated portable theme catalog and license.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
