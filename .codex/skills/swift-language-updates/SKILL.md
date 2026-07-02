---
name: swift-language-updates
description: Use when writing, reviewing, or modernizing Swift code based on recent Swift language, standard library, compiler, Swift Testing, SwiftPM, Foundation, interoperability, or ownership changes. Trigger for requests mentioning latest Swift, Swift 6.3, Swift 6.4, WWDC26 "What's new in Swift", changelogs, @diagnose, anyAppleOS, module selectors, @c/@implementation, task cancellation shields, ~Sendable, async defer, @inline(always), @specialize/@specialized, Iterable, borrow/mutate accessors, UniqueBox, UniqueArray, Ref/MutableRef, Swift Testing migration, Subprocess 1.0, Swift Build, Embedded Swift, Android SDK, Wasm, or Java interop.
---

# Swift Language Updates

## Overview

Use this skill to apply recent Swift release knowledge without guessing from memory. The root file is a router; load only the reference matching the requested release or feature family.

Official Swift and Apple documentation changes quickly. Treat these references as a July 2, 2026 snapshot. Before relying on a "latest" release claim, verify the current Swift.org install page, Swift changelog, Apple Developer page, or local toolchain.

## Before Coding

1. Check the active toolchain and language mode: `swift --version`, Xcode version, package `swift-tools-version`, and relevant `SWIFT_VERSION` / build settings.
2. Identify whether the target can require Swift 6.4-era snapshots/betas. As of this snapshot, Swift.org install navigation shows Swift 6.3.3 as current stable, while Apple Developer documents Swift 6.4 WWDC26 features.
3. Read the relevant reference:
   - `references/swift-6-4.md`: Swift 6.4 / WWDC26 language, library, testing, Foundation, interop, embedded, and ownership updates.
   - `references/swift-6-3.md`: Swift 6.3 stable release, patch guidance, Swift Build preview, Android SDK, C interop, and migration notes.
4. Prefer source-compatible, locally compiling changes over broad modernization. New attributes and protocols should be introduced only where they solve a concrete issue.
5. Run focused builds/tests after changing language features, compiler flags, package manifests, or test framework interop.

## Practical Rules

- Use Swift 6.4 features only when the local compiler accepts them or the user explicitly wants forward-looking/beta work.
- Do not mass-rewrite working code to new syntax solely because it exists.
- Keep `@diagnose` scoped to the smallest declaration that needs a warning override, and include a reason when suppressing or changing severity.
- Use `withTaskCancellationShield` for bounded cleanup/rollback work that must ignore ambient cancellation. Keep the shielded region short.
- Use optimizer control attributes only after measurement. They can trade speed for code size or hide dispatch constraints.
- Verify the specialization attribute spelling with the active compiler. Official Swift 6.3 release copy uses `@specialize`; the WWDC26 code listing shows `@specialized(where ...)`.
- When touching Apple OS availability, combine this skill with `modern-apple-frameworks` if framework deployment gates or iOS/macOS API availability are involved.
- When touching SwiftUI views, combine this skill with the appropriate SwiftUI skill.

## Source Triage

Use official sources first:

- Apple Developer "What's new in Swift": high-level Swift 6.4 Apple platform summary.
- WWDC26 session 262 "What's new in Swift": transcript, chapters, and code snippets.
- Swift.org blog/release posts: stable release summaries and install status.
- Swift repository `CHANGELOG.md`: compiler/language entries in reverse chronological order.
- Swift Evolution proposals: feature semantics and status.
- SwiftPM documentation and forums: package-manager build-system migration details.

Avoid relying on third-party summaries unless they point back to official sources and you are using them only to find the official material.
