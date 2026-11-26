#!/usr/bin/env python3
"""Keep concrete infrastructure and UI dependencies out of lower layers."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
allowed = {
    'LoffoDomain': {'Foundation'},
    'LoffoDocument': {
        'Foundation', 'OSLog', 'os', 'LoffoDomain', 'TreeSitter', 'TreeSitterTypeScript', 'TreeSitterTSX',
        'TreeSitterRust', 'TreeSitterJava', 'TreeSitterSwift', 'TreeSitterJSON', 'TreeSitterMarkdown',
    },
    'LoffoDiff': {'Foundation', 'OSLog', 'LoffoDomain'},
    'LoffoInfrastructure': {'Foundation', 'CoreServices', 'Darwin', 'os', 'LoffoDomain', 'LoffoDocument'},
    'LoffoDesignSystem': {'SwiftUI'},
    'LoffoEditorUI': {'AppKit', 'OSLog', 'SwiftUI', 'Foundation', 'LoffoDomain', 'LoffoDesignSystem'},
    'LoffoFeatures': {
        'Foundation', 'Combine', 'SwiftUI', 'AppKit', 'UniformTypeIdentifiers', 'LoffoDomain',
        'LoffoEditorUI', 'LoffoDesignSystem',
    },
}
errors = []
for module, imports in allowed.items():
    for file in (root / 'Packages/LoffoKit/Sources' / module).glob('*.swift'):
        actual = set(re.findall(r'^import (\w+)', file.read_text(), re.MULTILINE))
        for dependency in actual - imports:
            errors.append(f'{file.relative_to(root)}: forbidden import {dependency}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Module import boundaries passed ({len(allowed)} targets).')
