# Swift 6.3 Stable Snapshot

Source snapshot: July 2, 2026.

Official sources:
- Swift 6.3 release post: https://www.swift.org/blog/swift-6.3-released/
- Swift 6.3.3 announcement: https://forums.swift.org/t/announcing-swift-6-3-3/87888
- Swift changelog: https://raw.githubusercontent.com/swiftlang/swift/refs/heads/main/CHANGELOG.md
- Swift install page: https://www.swift.org/install/
- Embedded Swift 6.3 post: https://www.swift.org/blog/embedded-swift-improvements-coming-in-swift-6.3/
- SwiftPM release notes: https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/releasenotes/

## Current Stable Line

As of this snapshot, Swift.org install navigation points to Swift 6.3.3. The forum announcement says Swift 6.3.3 is available through Swiftly, direct toolchain downloads, Docker/WinGet rollout, and Xcode 26.6.

Swift 6.3.3 fixes several runtime/compiler issues, including `nonisolated(nonsending)` isolation transfer regressions in optimized variants and a REPL crash with async code. If investigating a 6.3 concurrency crash, first verify the project is not stuck on an older 6.3 patch.

## Language And Standard Library

- `@c` exposes Swift functions and enums to C through the generated C header.
- `@c @implementation` provides Swift implementations for existing C header declarations while checking signature compatibility.
- Module selectors use `ModuleName::symbol` to disambiguate APIs from imported modules.
- Concurrency and string-processing APIs can be qualified through the `Swift` module name.
- `@inline(always)` asks the compiler to inline direct calls when legal. Use only after measuring.
- Explicit specialization lets library authors pre-generate common generic specializations. Official Swift 6.3 release text uses `@specialize`; check the active compiler for accepted spelling.
- `@export(implementation)` exposes function bodies for client-side optimization in ABI-stable libraries.
- Codable errors have more readable debug descriptions.
- Some span/raw-byte APIs gained `@unsafe`; do not paper over these annotations without checking memory initialization and padding guarantees.

Example module selector:

```swift
import ModuleA
import ModuleB

let value = ModuleA::makeValue()
```

## Package And Build

- Swift Build is available as a SwiftPM preview in Swift 6.3 through `--build-system swiftbuild`.
- SwiftPM 6.4 makes Swift Build the default; keep 6.3 references explicit when bisecting package build issues.
- SwiftPM adds support for prebuilt Swift Syntax in shared macro implementation libraries.
- `swift package show-traits` discovers package traits.
- Documentation inheritance controls were added for command plugins that generate symbol graphs.

When changing package build behavior, run both the project's normal package build and the Swift Build variant if the project supports it:

```sh
swift build
swift build --build-system swiftbuild
```

## Swift Testing And DocC

- `Issue.record(..., severity: .warning)` records non-fatal Swift Testing issues.
- `try Test.cancel(...)` cancels an active test and its task hierarchy.
- Swift Testing supports image attachments on Apple and Windows platforms through relevant overlays.
- DocC gains experimental Markdown output, static HTML content for pages, and code-block annotations.

Use Swift Testing features incrementally. If existing helper APIs are XCTest-based, keep them stable until the suite is ready for the two-way interop described in Swift 6.4 materials.

## Platforms And Environments

- Swift 6.3 includes the first official Swift SDK for Android.
- Swift-Java and Swift Java JNI Core support integrating Swift into Android apps written in Kotlin/Java.
- Embedded Swift gains C interop improvements, better debugging, more library support, and linkage model progress.
- Embedded restriction diagnostics use the `EmbeddedRestrictions` warning group; this can be enabled outside Embedded Swift for cross-mode libraries.
- `@section` and `@used` support embedded/linker use cases. Use `#if objectFormat(...)` for object-format-specific sections.

## Migration Checklist

- Prefer `@c` over underscored C interop attributes when the compiler supports it.
- Reach for module selectors only to solve unavoidable name conflicts or generated-code robustness. Do not design new APIs that require clients to use them.
- Keep `@inline(always)`, explicit specialization, and `@export(implementation)` behind measurements and ABI review.
- If a project fails only under `--build-system swiftbuild`, check SwiftPM known issues before refactoring package structure.
- For Android or Embedded Swift work, verify SDK/toolchain availability locally before promising support in application code.
