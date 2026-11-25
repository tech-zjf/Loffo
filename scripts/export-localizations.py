#!/usr/bin/env python3
"""Export reviewed String Catalog entries for SwiftPM's command-line resource loader.

Xcode understands xcstrings; SwiftPM CLI consumes the equivalent .strings resources.
Run --check in CI to ensure the checked-in export matches the catalog.
"""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1] / 'Packages/LoffoKit/Sources'
for module in ['LoffoFeatures', 'LoffoDomain']:
    source = root / module / 'Localization/Localizable.xcstrings'
    catalog = json.loads(source.read_text())
    output = root / module / 'Resources/en.lproj/Localizable.strings'
    lines = []
    for key, entry in sorted(catalog['strings'].items()):
        value = entry['localizations']['en']['stringUnit']['value']
        lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};')
    content = '\n'.join(lines) + '\n'
    if '--check' in sys.argv:
        if not output.exists() or output.read_text() != content:
            raise SystemExit(f'Stale localization export: {output}')
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content)
