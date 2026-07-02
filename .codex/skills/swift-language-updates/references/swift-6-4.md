# Swift 6.4 / WWDC26 Snapshot

Source snapshot: July 2, 2026.

Official sources:
- Apple Developer "What's new in Swift": https://developer.apple.com/swift/whats-new/
- WWDC26 session 262 "What's new in Swift": https://developer.apple.com/videos/play/wwdc2026/262/
- Swift changelog: https://raw.githubusercontent.com/swiftlang/swift/refs/heads/main/CHANGELOG.md
- Swift 6.4 release process: https://forums.swift.org/t/swift-6-4-release-process/85421
- Swift install page: https://www.swift.org/install/

## Current Status Caveat

As of this snapshot, Swift.org install navigation still identifies 6.3.3 as the install release, and the Swift Evolution README lists Swift 6.4 as announced without a final release link. Apple Developer WWDC26 materials describe Swift 6.4 features. Treat Swift 6.4 as "documented by Apple, but verify local compiler support" before editing production code.

## Language Ergonomics

- Optional `some` / `any` usage no longer needs the old extra parentheses in common optional forms.
- Throwing unstructured tasks now warn when the created task is ignored. Fix by handling the error inside the task, explicitly discarding the task, or storing and awaiting it later.
- `defer` can contain `await` in async contexts. Use this for cleanup that must run on every return/throw path.
- `weak let` enables immutable weak references, which helps types that previously needed `@unchecked Sendable` only because of weak mutable storage.
- `~Sendable` explicitly marks a type as not Sendable while still allowing subclasses to become Sendable when they are safe.
- Structs with a mix of internal and private properties can gain an additional accessible memberwise initializer that excludes private defaults.

Example patterns:

```swift
defer {
    await resource.close()
}

class CacheHandle: ~Sendable {}
```

## Availability And Diagnostics

Use `anyAppleOS` when all Apple platform versions line up:

```swift
@available(anyAppleOS 26.0, *)
func useUnifiedAppleAvailability() {}

#if os(anyAppleOS)
// Apple-platform-only code
#endif
```

Use platform-specific entries for exceptions:

```swift
@available(anyAppleOS 26.0, *)
@available(tvOS, unavailable)
func unavailableOnTV() {}
```

Use `@diagnose` for local warning control. Keep it narrow and explain suppression:

```swift
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Remove after legacy sync migration")
func temporaryBridge() {
    legacyAPI()
}
```

Useful groups mentioned in official materials include `DeprecatedDeclaration`, `StrictMemorySafety`, `ErrorInFutureSwiftVersion`, and `EmbeddedRestrictions`. Verify group names against the compiler when adding new uses.

## Concurrency And Standard Library

- `withTaskCancellationShield` temporarily hides ambient cancellation from checks inside the closure. Use it for short cleanup, commit, or rollback sections.
- `Dictionary.mapKeyedValues` maps values while also receiving the key.
- `FilePath` moves Swift System-style path manipulation into the standard library.

Example:

```swift
withTaskCancellationShield {
    persistFinalCheckpoint()
}

let displayNames = launches.mapKeyedValues { mission, window in
    displayName(for: mission, window: window)
}
```

## Swift Testing

- `Issue.record(..., severity: .warning)` records non-fatal issues.
- `try Test.cancel(...)` dynamically cancels a running test, which is especially useful for individual parameterized-test arguments.
- `swift test` adds repeat-until-pass/fail style options for flaky test investigation. Check `swift test --help` in the active toolchain for exact flags.
- XCTest assertions called from Swift Testing now surface as test issues. Swift Testing expectations can also be called from XCTest. Interop issues are warnings by default, with build settings available to promote them.

Use this to migrate incrementally instead of converting entire suites in one pass.

## Subprocess And Foundation

- Subprocess reaches 1.0 with refined execution types, better errors, cross-platform descriptors/statuses, and easier output streaming through async sequences.
- Foundation adds `ProgressManager` for async/await-friendly progress composition and reporting.
- Foundation's Swift migration improves `Data`, `NSData` bridging, and URL internals. Apple summarizes URL parsing as much faster on the Swift 6.4 page.

Avoid changing production subprocess code from older package APIs until the active dependency/toolchain exposes Subprocess 1.0.

## Interoperability And Platforms

- The C interop attribute is shown in code as `@c`; WWDC prose may capitalize it as `@C`. Use compiler-accepted spelling.
- Combine `@c` with `@implementation` to implement an existing C declaration in Swift without generating a duplicate C declaration.
- Swift can bridge Swift spans to C, and C++ interop supports C++20 span bridging.
- Swift-Java expands support for async/throwing Swift functions from Java, constrained extensions, and Java classes conforming to Swift protocols.
- Swift.org provides an official Android SDK in the Swift 6.3 line; WWDC26 frames Android as part of the cross-platform story.
- The Swift VS Code extension adds Swiftly integration and OpenVSX availability for editors such as Cursor and VSCodium.
- WebAssembly support and JavaScriptKit improvements make Swift-to-JavaScript bridging safer and faster.
- Embedded Swift expands to existential types, untyped throws, and better DWARF debug info for core dump inspection.

## Optimizer And Ownership

Use these only for measured hot paths:

- `@inline(always)` requests forced inlining when legal. Pair with `final` on class methods when dynamic dispatch would prevent inlining.
- Explicit specialization creates concrete versions of generic functions for important type constraints. Verify active spelling: Swift 6.3 release text says `@specialize`, while WWDC26 code shows `@specialized(where ...)`.
- Noncopyable and nonescapable support expands to core protocols and associated types.
- `Iterable` enables borrow-based `for` loops, including noncopyable elements, with span-batched iteration.
- `borrow` and `mutate` accessors allow computed properties to expose storage without get/set copying.
- New standard library types include `UniqueBox`, `UniqueArray`, `Continuation`, `Ref`, and `MutableRef`.
- `withTemporaryAllocation` can use `OutputSpan` for safer temporary memory handling.

Example shape for accessors:

```swift
var value: Value {
    borrow { storage.pointee }
    mutate { &storage.pointee }
}
```

Review checklist:
- Measure before adding optimizer attributes.
- Prefer `Sequence` unless you need noncopyable/borrow iteration or measured refcount-copy reduction.
- Keep unsafe pointer wrappers small and audited if using `borrow`/`mutate` around manual storage.
- Verify ownership features compile under the package's Swift language mode.

## Migration Checklist

- Confirm the compiler version supports the feature.
- Use `anyAppleOS` only when all Apple platform availability really aligns.
- Replace broad warning suppressions with narrow `@diagnose` only when there is a planned removal or audit path.
- Fix unhandled throwing `Task` warnings by preserving task errors, not by silencing the warning.
- Prefer Swift Testing/XCTest interop for gradual migration.
- Keep C interop changes ABI/header-compatible and inspect generated headers where possible.
- Add performance attributes behind benchmarks, not style preference.
