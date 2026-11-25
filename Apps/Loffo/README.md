# Loffo app

SwiftUI composition root; Swift Package executable, macOS 14 deployment target. Open `Package.swift` in Xcode or run `../../scripts/build-app.sh release` from this directory.

`LoffoApp.swift` owns shared adapters and per-window models. `Info.plist` and the root packaging script create a local ad-hoc-signed app; signing/notarization for distribution remains pending.

Debug only: `Loffo --project <folder> --file <relative path> [--diff] --smoke-screenshot <png>` renders the application's own view tree and exits. Release excludes the capture implementation.
