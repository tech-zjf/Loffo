#!/usr/bin/env python3
"""Check statically declared UI/error keys against their owning String Catalog.

Dynamic filenames, Git subjects and OS diagnostics stay verbatim. Conditional UI keys
are reviewed in the catalog; this check does not claim Swift parser-level extraction.
"""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1] / 'Packages/LoffoKit/Sources'
keys = {
    name: set(json.loads((root / name / 'Localization/Localizable.xcstrings').read_text())['strings'])
    for name in ['LoffoFeatures', 'LoffoDomain']
}
errors = []
for path in root.glob('*/*.swift'):
    source = path.read_text()
    for prefix, module in [('L10n', 'LoffoFeatures'), ('DomainStrings', 'LoffoDomain')]:
        for match in re.finditer(rf'{prefix}\.(?:text|format)\(\s*"([^"\\]*)"', source):
            if match.group(1) not in keys[module]:
                errors.append(f'{path.name}: missing {module} key: {match.group(1)}')
    for match in re.finditer(r'WorkspaceFailure\.(?:unavailable|unsupportedComparison)\(\s*"([^"\\]*)"', source):
        if match.group(1) not in keys['LoffoDomain']:
            errors.append(f'{path.name}: missing error key: {match.group(1)}')
    if path.parent.name == 'LoffoFeatures':
        for match in re.finditer(r'\b(?:Text|Button|Label|accessibilityLabel|help)\(\s*"([A-Za-z][^"\\]*)"', source):
            if match.group(1) not in ['Loffo', 'HEAD']:
                errors.append(f'{path.name}: raw product text needs L10n: {match.group(1)}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Static UI and error localization keys passed.')
