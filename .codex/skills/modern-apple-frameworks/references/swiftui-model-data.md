# SwiftUI Model Data With Observation

## When To Read

Read this when writing SwiftUI views that own, receive, edit, or share model data, or when migrating `ObservableObject`/`@Published` code to the Observation framework.

## Source Snapshot

- Managing model data in your app: https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app
- Migrating from `ObservableObject` to `@Observable`: https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro
- `Bindable`: https://developer.apple.com/documentation/swiftui/bindable
- `environment(_:)`: https://developer.apple.com/documentation/swiftui/view/environment(_:)
- Observation core docs listed in `observation-core.md`

## Availability

SwiftUI Observation support is available starting iOS 17, iPadOS 17, macOS 14, tvOS 17, watchOS 10, and Xcode 15. Inline's stated floor is iOS 18 and macOS 15, so Observation is available for normal app code.

## Dependency Tracking

- SwiftUI forms a dependency when a view's `body` reads an observable property.
- If `body` does not read a property, changing that property does not update that view.
- Passing an observable object through intermediate views does not make those views observe it unless they read observable properties.
- Collection reads track collection changes. Row/content closures usually track the individual element properties they read, so a row title change can update only that row.
- Computed properties update views through the observable properties they read.

## Ownership Patterns

Use `@State` for an observable object that a SwiftUI view, scene, or app owns:

```swift
@Observable
final class Library {
    var books: [Book] = []
}

struct LibraryRoot: View {
    @State private var library = Library()

    var body: some View {
        LibraryView()
            .environment(library)
    }
}
```

Read a shared observable object from the environment by type:

```swift
struct LibraryView: View {
    @Environment(Library.self) private var library

    var body: some View {
        List(library.books) { book in
            BookRow(book: book)
        }
    }
}
```

Use a plain property for an injected observable object when the child only reads it:

```swift
struct BookRow: View {
    let book: Book

    var body: some View {
        Text(book.title)
    }
}
```

Use `@Bindable` only when the view needs bindings to mutable properties:

```swift
struct BookEditView: View {
    @Bindable var book: Book

    var body: some View {
        TextField("Title", text: $book.title)
        Toggle("Available", isOn: $book.isAvailable)
    }
}
```

For environment or local values, create a local bindable variable in `body`:

```swift
struct TitleEditView: View {
    @Environment(Book.self) private var book

    var body: some View {
        @Bindable var book = book
        TextField("Title", text: $book.title)
    }
}
```

## Migration From ObservableObject

1. Replace `ObservableObject` conformance with `@Observable`.
2. Remove `@Published` from observable properties.
3. Add `@ObservationIgnored` to accessible properties that should not be tracked.
4. Replace `@StateObject` with `@State` for owned observable objects when fully migrating.
5. Replace `@ObservedObject` with a plain property unless the child needs bindings; use `@Bindable` for bindings.
6. Replace `.environmentObject(model)` and `@EnvironmentObject` with `.environment(model)` and `@Environment(Model.self)`.
7. Expect narrower updates: `ObservableObject` invalidates for any published property; Observation invalidates a view only for properties its `body` reads.

SwiftUI supports mixing `ObservableObject` and `@Observable` during incremental migration, but avoid that as an end state unless compatibility requires it.

## Avoid

- Do not use `@StateObject` for new `@Observable` state unless you are intentionally keeping an incremental migration bridge.
- Do not add property wrappers to model properties just to make them observable.
- Do not read broad model properties in high-level views when only leaf views need them.
- Do not place high-frequency global state in the environment if passing a narrow value would reduce view invalidation.

## Review Checklist

- Owned observable reference models use `@State`.
- Injected observable models are plain properties unless bindings are needed.
- `@Bindable` appears only where bindings are created.
- Environment injection and reads use `.environment(model)` and `@Environment(Model.self)`.
- Migration removed stale `@Published`, `@ObservedObject`, `@StateObject`, and `@EnvironmentObject` where appropriate.
