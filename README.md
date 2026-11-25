# Loffo

A native macOS, local-first, read-only code reader and Git change review prototype.

## Build

Requires Xcode and Swift 6. Dependencies are pinned in Package.resolved.

```sh
scripts/check.sh
scripts/build-app.sh release
open build/Loffo.app
```

The prototype supports UTF-8 files within its documented limits and a bounded subset of Git comparisons. Some Git states and performance and accessibility acceptance remain incomplete.
