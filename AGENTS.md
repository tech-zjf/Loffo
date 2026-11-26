# Loffo engineering conventions

Loffo is a native macOS code reader and change reviewer. Keep the main workflow local and read-only. The approved assets live under `designs/`; never replace originals with implementation screenshots.

Loffo's product priorities are exceptionally low resource use, responsiveness and visual quality. Treat all three as release requirements: measure memory, CPU and latency in realistic single- and multi-project workflows, validate visual and interaction quality in the real app, and fix the underlying design when a requirement is missed. Never claim a target is met without matching evidence.

## Before a change

- Read `docs/core-contracts.md` and `docs/implementation-status.md`. The architecture describes the target; the status document records the implemented subset and unpassed gates.
- Fix the underlying design or correctness issue, not just its visible symptom. This project is early-stage: refactor the affected ownership, data flow, state model or shared component when needed, and remove obsolete paths instead of layering one-off workarounds, silent fallbacks or permanent compatibility shims. Apply this rule throughout the project, including UI, infrastructure, performance, tests and tooling.
- For complex behavior, research relevant primary sources and implementations such as Zed or VS Code before choosing a design. Adapt their underlying ideas to Loffo's language, native platform and read-only contracts; do not copy filtering rules or behavior without verifying their assumptions and failure modes.
- Validate the root-cause fix across the complete affected flow, including errors, cancellation, lifecycle and multi-window behavior where relevant. Add meaningful regressions and real-app evidence for user-visible changes; record actual limits and unfinished acceptance without declaring a workaround complete.
- Keep changes within the current milestone. Do not add AI chat, accounts, terminal, Git mutations or a plugin framework implicitly.
- Fix a discovered correctness defect with a regression test. Do not claim G1–G4 passed from a build, a screenshot or unit tests.

## Modules

- `LoffoDomain`: immutable models, versioning, errors and capability protocols. Foundation only; no UI, C parser or concrete service dependencies.
- `LoffoDocument`: bounded snapshot loading and parser ownership. Tree-sitter pointers never cross this module.
- `LoffoDiff`: deterministic comparison over immutable input. No filesystem, Git or UI imports.
- `LoffoInfrastructure`: filesystem, observation and Git adapters. All Git execution goes through `GitRunner` with argument arrays, limits and cleanup.
- `LoffoDesignSystem`: shared visual tokens and reusable presentation elements; no business services.
- `LoffoEditorUI`: AppKit/TextKit surface, selection, layout and viewport decoration. It receives presentations, not repository paths to read itself.
- `LoffoFeatures`: window-owned state and use cases, depending on domain protocols. No direct Process, FileHandle or parser APIs.
- `Apps/Loffo`: composition root, application lifecycle, configuration and app resources. Instantiate shared services here and inject dependencies.
- Prefer a concrete value type or helper before a new protocol. Add protocols only at real replaceable/test boundaries. No global service locator.

## Correctness and performance

- UI state belongs to MainActor. Blocking work uses a bounded operation queue. No blocking waits, Git scans, full-file decoding or syntax parsing in a View body.
- Separate window intent, content version and refinement version. Validate after every asynchronous boundary before publishing. Closing one subscriber must not cancel another window's shared resources.
- Keep one running refresh and one pending signal per window; budgets apply to caches, process output, parser and Diff work. State explicit limits instead of silently truncating a result.
- Preserve raw text and terminators. UTF-8 offsets and UTF-16 ranges are different coordinate systems. Never feed parser byte ranges directly to NSTextView.
- Avoid full attributed-text replacement on refresh. Maintain selection and a logical reading anchor; don't overwrite newer user scrolling with an older computed anchor.
- Model errors explicitly. A failed read is not an empty file; an unsupported comparison is not “no changes”. Never use `try?` to turn data loss into success. Best-effort teardown may use `try?` with narrow scope.
- No force unwraps, `try!` or blanket `@unchecked Sendable` without a documented invariant and test. Do not disable Swift concurrency checking to fix compiler errors.
- Share immutable data, not window selection/layout state. Introduce global byte admission and visibility-aware scheduling before claiming multi-window budgets.

## Readability and checks

- Swift 6 language mode; 4-space indentation and 110-column formatting in `.swift-format`.
- Prefer one primary responsibility per file. Split mixed algorithm, UI adapter and process lifecycle code. Name units and ownership explicitly; comments explain invariants and tradeoffs.
- Run `scripts/check.sh` for source changes; it checks formatting, module import boundaries and behavior tests. Run `scripts/build-app.sh release` before handing over an app.
- Validate visual changes with the real app. Debug `--smoke-screenshot` captures this application's view hierarchy; it is excluded from Release.
- Record test environment, actual evidence and unresolved limitations in `docs/implementation-status.md`. Keep architecture contracts and implementation status consistent.
- Do not commit generated builds, traces, dependency checkouts or the entire design library as runtime resources. Pin dependency versions and keep resolved files.
