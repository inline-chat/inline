---
name: test-modernizer
description: Modernize existing Swift test suites by migrating XCTest to Swift Testing or improving current Swift Testing structure. Use when asked to modernize, update, migrate, supercharge, or convert tests. Do not use for writing new tests from scratch, XCTest-only questions, test result review, test running, coverage updates for new functionality, debugging failures without a migration request, or XCUI UI automation tests.
---

# Test Modernizer

Apply when the user asks to modernize, update, migrate, supercharge, or convert their tests.
XCTest should be migrated to Swift Testing when possible, and existing Swift Testing tests should be evaluated for better structure and newer features.

Do not apply when the user asks to write new tests from scratch without existing XCTest code, asks about XCTest features only, only asks about
test results or test running, asks to update tests to cover new functionality rather than updating the tests themselves,
is debugging test failures without mentioning migration, or has UI automation tests using XCUI* APIs, since these cannot be migrated to Swift Testing.

## Migration Reference

### Imports

Replace `import XCTest` with `import Testing`. A file can import both if it contains mixed test content during incremental migration.

When removing import XCTest, check whether the file uses Foundation types such as `URL`, `CharacterSet`, `ProcessInfo`, or `Data`. XCTest re-exports
Foundation, so add `import Foundation` if needed.

### Test Classes to Suites

Remove `XCTestCase` inheritance. Prefer `struct` over `class`:

- `final class FoodTruckTests: XCTestCase { ... }` -> `struct FoodTruckTests { ... }`

### setUp/tearDown to init/deinit

Replace `override func setUp()` with `init()`, which can be `async throws`. Replace `override func tearDown()` with `deinit`. If `deinit` is needed, use
`actor` or `final class` instead of `struct`, since structs have no `deinit`. Change stored properties to not use implicitly-unwrapped optional
types, and move their initial assignment from `setUp` to either be initialized inline or, if the initialization is complex, in an initializer.

```swift
struct MyTests {
    var fixture = Fixture()
    mutating func `Fixture behaves as expected`() {
        #expect(fixture.doSomething())
    }
}
```

Avoid pulling instance variables into function bodies; this can cause noise. Swift Testing reinvokes the initializer fresh before each test runs.
If the test mutates an instance variable with value semantics, mark the test function `mutating`.

### Test Methods

Replace the `test` name prefix with the `@Test` attribute. If the resulting test name includes multiple camelCase words,
use a raw identifier with the test name in sentence case.

- `func testEngineDoesNotStall() { ... }` -> `@Test func `Engine does not stall`() { ... }`
- `func testIgnition() { ... }` -> `@Test func ignition() { ... }`

Test functions can be `async`, `throws`, or `async throws`, and can be isolated to a global actor with `@MainActor`.

### Assertions to Expectations

When migrating a test from XCTest to Swift Testing, apply these mappings:

- `XCTAssert(x)`, `XCTAssertTrue(x)` -> `#expect(x)`
- `XCTAssertFalse(x)` -> `#expect(!x)`
- `XCTAssertNil(x)` -> `#expect(x == nil)`
- `XCTAssertNotNil(x)` -> `#expect(x != nil)`
- `XCTAssertEqual(x, y)` -> `#expect(x == y)`
- `XCTAssertNotEqual(x, y)` -> `#expect(x != y)`
- `XCTAssertIdentical(x, y)` -> `#expect(x === y)`
- `XCTAssertNotIdentical(x, y)` -> `#expect(x !== y)`
- `XCTAssertGreaterThan(x, y)` -> `#expect(x > y)`
- `XCTAssertGreaterThanOrEqual(x, y)` -> `#expect(x >= y)`
- `XCTAssertLessThanOrEqual(x, y)` -> `#expect(x <= y)`
- `XCTAssertLessThan(x, y)` -> `#expect(x < y)`
- `try XCTUnwrap(x)` -> `try #require(x)`

There is no direct equivalent for `XCTAssertEqual(_:_:accuracy:)`; use floating point math directly.

### Errors

When the error type is `Equatable` and the exact value is known, prefer to check the specific error value.

```swift
XCTAssertThrowsError(try f())
```

becomes:

```swift
#expect(throws: (any Error).self) {
    try f()
}
```

```swift
XCTAssertThrowsError(try f()) { error in
    XCTAssertEqual(error, specificError)
}
```

becomes:

```swift
#expect(throws: specificError) {
    try f()
}
```

```swift
XCTAssertThrowsError(try f()) { error in
    // Check error
}
```

becomes:

```swift
let error = #expect(throws: (any Error).self) {
    try f()
}
// Check error
```

```swift
XCTAssertNoThrow(try f())
```

becomes:

```swift
#expect(throws: Never.self) {
    try f()
}
```

### continueAfterFailure

By default `continueAfterFailure` is true, which means expectations do not halt the test run.
Some XCTestCases set `continueAfterFailure = false`, which means the `XCTAssert` family of functions
will throw Objective-C exceptions that halt the test execution.

When a test method sets `continueAfterFailure = false`, all subsequent assertions need to be `try #require(x)`
instead of `#expect(x)` to preserve this behavior. When adding `try #require(x)`, add `throws` to the affected methods.

When `continueAfterFailure = false` is set in `setUp`, the conversion to `try #require(x)` must apply
to all assertions in all test methods in that class.

### Promote `Issue.record`/`XCTFail` to expectations

Wherever it is not disruptive, convert usage of `Issue.record` or `XCTFail` to `#expect` or `#require`,
depending on whether the test exits after, taking `continueAfterFailure` into account.

In some cases, the source of the expectation itself is sufficient to explain the failure,
and the comment would be redundant.

For example, the following structures should be converted as such:

```swift
guard let object = somethingOptional() else {
    Issue.record("Could not get object")
    return
}

guard object.isAvailable() else {
    Issue.record("Object not available")
    return
}

if !object.performOperation() {
    Issue.record("Failed to perform operation")
}
```

becomes:

```swift
let object = try #require(somethingOptional(), "Could not get object")
try #require(object.isAvailable())
#expect(object.performOperation())
```

### Asynchronous Expectations to Confirmations

Replace `XCTestExpectation` + `fulfill()` + `await fulfillment(of:)` with `confirmation()`:

```swift
// Before
let exp = expectation(description: "...")
handler = { exp.fulfill() }
doWork()
await fulfillment(of: [exp])

// After
await confirmation("...") { confirm in
    handler = { confirm() }
    doWork()
}
```

For `assertForOverFulfill = false` with an `expectedFulfillmentCount`, use a range:
`await confirmation("...", expectedCount: 10...) { confirm in ... }`

### Skipping Tests

Replace `XCTSkipIf`/`XCTSkipUnless` with traits on the test or suite:

- `try XCTSkipIf(condition)` -> `@Test(.disabled(if: condition))`
- `try XCTSkipUnless(condition)` -> `@Test(.enabled(if: condition))`

Replace `throw XCTSkip("reason")` mid-test with `try Test.cancel("reason")`.

When a skip checks OS version or platform availability, replace it with an `@available` attribute on the test function instead of `.enabled(if:)`.

### Known Issues

Replace `XCTExpectFailure("...", ...) { ... }` with `withKnownIssue("...") { ... }`.

For intermittent failures, replace `.nonStrict()` option or the shorthand `strict: false` parameter with `isIntermittent: true`.

For conditional or matching failures, use `when:` and `matching:` parameters:

```swift
withKnownIssue("...") {
    try riskyOperation()
} when: {
    shouldExpectFailure
} matching: { issue in
    issue.error != nil
}
```

### Concurrency and Serial Execution

XCTest runs synchronous tests on the main actor and sequentially within a suite by default. Swift Testing runs all test functions on an arbitrary task
and in parallel. Add `@MainActor` only if a test explicitly relied on main-actor isolation in its XCTest form, and add `@Suite(.serialized)` if
tests depend on shared state.

### Attachments

Replace `XCTAttachment` + `self.add(attachment)` with `Attachment.record(value)`. The attached type must conform to `Attachable`.
Foundation automatically supports `Codable` and `NSSecureCoding` types when Foundation is imported.

## Modernization Guidelines

- When migrating from XCTest, migrate one test class at a time. A file can contain both XCTest and Swift Testing tests during migration.
- Prefer `struct` for suites unless `deinit` or teardown is needed, in which case use `actor` or `final class`.
- Remove the `test` prefix from method names when adding `@Test`. For lengthier test names which read like a sentence, use raw identifier syntax to improve readability, for example `@Test func `Authenticate, fetch summary, then check count`() { ... }`.
- Check existing `@Test` functions for multi-word camelCase names and convert those to sentence-case raw identifiers.
- Use raw identifier syntax only for multi-word names that read like a sentence.
- When migrating `setUp`, convert implicitly-unwrapped optional properties to non-optional properties initialized in-place, or in `init` if initialization is complex, may throw, or is async.
- Look for explicit `XCTFail` or `Issue.record` calls that could be converted to `#expect` or `#require`.
- Do not change `try #require` calls into `#expect`; this changes the behavior of tests.
- Add `@MainActor` only to tests that explicitly relied on XCTest's implicit main-actor isolation. Do not add it unnecessarily.
- Look for tests that loop over inputs or many repeated tests with the same logic and convert them to parameterized tests using `@Test(arguments:)`.
- For suites with shared mutable state between tests, add `@Suite(.serialized)` and consider using `actor` or `class` instead of `struct`.
- Do not use underscore-prefixed symbols such as `#_sourceLocation`; only use public API. For source locations, always use the full `SourceLocation(fileID:filePath:line:column:)` initializer.
