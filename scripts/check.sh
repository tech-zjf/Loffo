#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
swift format lint --strict -r Apps/Loffo/Sources Packages/LoffoKit/Sources Packages/LoffoKit/Tests
swift format lint --strict Apps/Loffo/Package.swift Packages/LoffoKit/Package.swift
python3 scripts/check-module-boundaries.py
python3 scripts/export-localizations.py --check
python3 scripts/check-localization-coverage.py
swift test --package-path Packages/LoffoKit
