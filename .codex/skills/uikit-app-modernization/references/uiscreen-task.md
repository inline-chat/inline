# Task: UIScreen.main Modernization

## Overview

`UIScreen.main` reflects a single-window assumption and is now deprecated for window-relative use. Modern iOS supports multiple windows (iPad multitasking, Stage Manager, iPhone Mirroring), where `UIScreen.main` may not represent the display the calling code is rendering on.

**Detection patterns:**

- `UIScreen.main.scale` / `UIScreen.mainScreen.scale`
- `UIScreen.main.bounds` / `UIScreen.mainScreen.bounds`
- `UIScreen.main.nativeBounds` / `UIScreen.mainScreen.nativeBounds`
- `UIScreen.main.nativeScale` / `UIScreen.mainScreen.nativeScale`
- `UIScreen.main.traitCollection` / `UIScreen.mainScreen.traitCollection`
- `UIScreen.main.coordinateSpace` / `UIScreen.mainScreen.coordinateSpace`
- `UIScreenBrightnessDidChangeNotification` with `UIScreen.main`/`UIScreen.mainScreen` as object

**Less-obvious sites that ALSO require modernization (do NOT produce empty diffs on them):**

- **Nil-screen fallbacks** — `screen == nil ? [UIScreen mainScreen] : screen`, `self.window.screen ?: [UIScreen mainScreen]`, `screen ?? UIScreen.main`. The `[UIScreen mainScreen]` fallback IS a target site, even when wrapped in a nil check. See the [Fallback Paths](#fallback-paths) section below for the full handling.
- **Private helpers whose only `UIScreen` use is "incidental"** — e.g., a `-(CGFloat)pixelWidth` helper that internally reads `[UIScreen mainScreen].scale`. The helper is the deprecation target, even if the caller looks unrelated to display rendering.
- **Cached `dispatch_once` / static-let / lazy-var helpers** that read `UIScreen.main` once at first call and freeze the value (e.g., `mainScreenScale()`, `isLargeDevice()`, `isRetina()`). The helper itself is the target.
- **`UIScreen.main` passed as an argument to another function** — e.g., `MapsIdiomIsMac(UIScreen.mainScreen)`, `UIRoundToScreenScale(value, UIScreen.mainScreen.scale)`. The argument is the target site; modernize it via the helper's own `traitCollection`/parameter migration if available, or via deprecate-and-forward on the helper. **However, only edit such an argument when the user explicitly asks for it — otherwise leave it for its own task per the off-target replacement guard ([Core Principle 16 in SKILL.md](../SKILL.md#core-principles)).**
- **Hardware/screen assumptions where a TODO is the right output** — when there's no safe replacement (e.g., `UIScreen.main.nativeScale` with no trait-collection equivalent in a context where the call site can't yet receive a window), a TODO explaining the assumption IS the right output. Producing no diff is wrong — produce the TODO.

If a target appears outside this list (e.g., a safe-area-inset bug, a coordinate-space conversion site, a private method rename), follow the active task's reference file. The skill must NOT skip files because "this isn't a `.scale` substitution" — the trigger is the deprecated API appearing in a site, not the specific shape of the expression.

**File-naming heuristic for non-view classes.** Files named `*Manager.m`, `*Provider.m`, `*DataProvider.m`, `*Bridge.m`, `*Helper.m`, `*Generator.m`, `*Ingester.m`, `*Source.m`, `*Downloader.m`, `*Processor.m`, `*ViewModel.swift` are virtually never UIView/UIViewController subclasses. In these files, apply deprecate-and-forward (Pattern 1, step 5) with a new overload taking `traitCollection: UITraitCollection`.

---

## Pattern 1: UIScreen.main.scale → traitCollection.displayScale

**Intent:** Get display scale for pixel-perfect rendering (2x, 3x).

These rules apply to any `UIScreen.main.traitCollection` access, not just `.displayScale`. The context (view vs non-view) determines the approach, regardless of which trait is being accessed.

**Shared state is not a valid replacement.** `[UITraitCollection currentTraitCollection]` / `UITraitCollection.current` carries the same single-display assumption as `UIScreen.main` and produces incorrect results in multi-window environments. Substituting it for `UIScreen.main` is not a modernization — it just renames the bug. The **only** legitimate use is as the forwarding bridge inside the deprecated wrapper of the deprecate-and-forward pattern (step 5), where the wrapper exists solely to point callers at a new overload that accepts `traitCollection:` explicitly. Anywhere else — view code, SwiftUI, free functions, helpers, fallbacks, examples — it is wrong. Treat the rest of this document accordingly: the only place you should write `.current` / `currentTraitCollection` is in the body of a deprecated forwarding wrapper.

**Decision tree — follow in order, stop at the first match:**

1. **User provides an explicit replacement expression?** → Use it exactly. The user chose that path for correct scene/window context. Never substitute a different path — the named path reflects the correct display context for that code site, and any substitute loses scene-specific information.
2. **SwiftUI `View` struct?** → Use `@Environment(\.displayScale) private var displayScale` as a property, then use `displayScale` at the call site. For `UIScreen.main.bounds`, use `GeometryReader` instead. **Do NOT apply deprecate-and-forward to SwiftUI views.** Even when the SwiftUI view has scale-dependent computation that "looks like" it would benefit from a `traitCollection:` parameter, the correct fix is `@Environment(\.displayScale)` — SwiftUI's environment propagation is the native mechanism. Introducing a `traitCollection: UITraitCollection` overload on a SwiftUI view is always wrong; it ignores the environment and forces callers to compute UIKit state in SwiftUI contexts.
3. **UIView or UIViewController subclass (or extension), in an instance method?** → `self.traitCollection.displayScale`. For class methods and static methods on view subclasses, skip to step 5 (deprecate-and-forward).
4. **View/VC or trait collection reachable through a property or method parameter?** → That object's `.traitCollection.displayScale` (e.g., `self.contentView.traitCollection.displayScale` or `detailViewController.traitCollection.displayScale`). **Always prefer the most local source.** Before constructing a path like `self.editorViewController.contentView.traitCollection.displayScale`, check whether a shorter source is available:
   - **Method parameters first (highest priority):** If the method receives a view controller, view, or any object that already carries the value, use it directly. Do not navigate through the view hierarchy to get `displayScale` separately. **A method that receives a `traitCollection` parameter and ignores it is always wrong.**
   - **Local variables and direct properties next:** If a local variable or direct property (`self.traitCollection`) already has the needed value, prefer it over traversing a longer chain. If `self` has a view property (e.g., `self.view`, `self.contentView`), use `self.view.traitCollection.displayScale`.
   - **Multi-hop chains last:** Only use a multi-hop path (3+ property accesses) when no shorter source exists. A long chain is fragile and harder to read. It also increases the risk of no longer providing the correct local value.
   
   **This step takes priority over step 5 ONLY when the class itself is a UIView/UIViewController subclass** (i.e., the method is an instance method on a view/VC and you're reaching another view's traitCollection). If the class is a **non-view class** (`*Manager`, `*Generator`, `*Provider`, `*Bridge`, `*Helper`, `*Source`, etc.), **step 5 (deprecate-and-forward) still applies** — even if a view/VC is reachable via a property or parameter. In that case, use the reachable view's `.traitCollection` **inside the new overload's body**, but still create the three-part deprecation pattern. Simply inlining `parameter.traitCollection.displayScale` in a non-view class is a regression — it hides the traitCollection dependency from callers.
   
   **Exception:** When a method already receives a `traitCollection:` parameter, use `traitCollection.displayScale` inside the body — no deprecation needed because the caller already provides the trait collection.
5. **Non-view class, utility, static method, class method, or free function?** → Apply the deprecate-and-forward pattern: keep the original method as a deprecated wrapper, add a new overload taking `traitCollection: UITraitCollection`, and have the deprecated wrapper forward to the new overload. This is the only context where shared state belongs in the forwarding body — see the [pattern below](#deprecate-and-forward-pattern-non-view-classes) for the exact shape.

   **Exception — smallest possible edit for file-local helpers:** When the symbol meets ALL of the following, skip the deprecate-and-forward overhead and instead modify the existing signature in place, updating callers to pass `traitCollection`:
   - **Access:** `private` / `fileprivate` / `static` (Swift) or static C function / file-local helper (ObjC, no header declaration)
   - **Reach:** All call sites are in the same file (or in test code targeting only this file)
   - **Caller context:** Every call site has a `traitCollection` reachable (typically `self.traitCollection` from a UIView/UIViewController, or a parameter already in scope)
   - **No public surface:** The symbol is not part of a header, public API, protocol requirement, or `@objc` exposed surface

   For these symbols, the deprecate-and-forward pattern is over-introducing API surface — there are no external callers to protect. Inline the change: add the `traitCollection` parameter to the existing method, update the callers in the same file to pass `self.traitCollection` (or the appropriate local trait source), and ship a single coherent edit. This is the preferred choice for private helpers, single-file utilities, and test helpers.

   **Default to deprecate-and-forward** when (a) the symbol is `public` / `internal` / `open`, (b) the symbol is declared in a header (ObjC), (c) callers exist in other files/modules that can't be updated atomically in this diff, or (d) the symbol is part of a protocol or override hierarchy. The full three-part pattern is mandatory in those cases.

   **Threading the trait collection through callers:** When you keep the deprecated wrapper, callers that have a view/VC in scope must be updated separately to call the new overload directly with `self.traitCollection` — do not leave them on the deprecated path. Producing a new overload but leaving every caller on the deprecated wrapper defeats the purpose of the migration.

   Applies to ALL access levels and **both Swift and ObjC** — ObjC class methods follow the same pattern. Place new parameter before any trailing closure. See the [ObjC class method example](#deprecate-and-forward-pattern-non-view-classes) below.

| Context | Replacement |
|---------|-------------|
| **SwiftUI `View` struct** | `@Environment(\.displayScale) private var displayScale` |
| UIView/UIViewController subclass | `self.traitCollection.displayScale` |
| View/VC reachable via property or method parameter | `someView.traitCollection.displayScale` (prefer the most local source) |
| Non-view class / static / class method / free function | Deprecate-and-forward with `traitCollection: UITraitCollection` parameter |
| Test code | Use the object-under-test's `traitCollection` |

### Two-part pattern: API swap + invalidation

A replacement in a view/VC has two parts: (A) the API swap, and (B) a `registerForTraitChanges` call when the value is cached. Both parts are mandatory for cached values — a diff with only part A is incomplete.

**Both parts below are mandatory for cached values. Do not skip part B.**

```swift
// COMPLETE — replacement + invalidation (both parts required)
class MyCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        imageView.layer.contentsScale = traitCollection.displayScale
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: MyCell, previousTraitCollection) in
            self.imageView.layer.contentsScale = self.traitCollection.displayScale
        }
    }
}
```

> **ObjC equivalent:** `[self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(typeof(self) self, UITraitCollection *previousTraitCollection) { ... }]` or use `withAction:@selector(methodName)` for a separate method.

Part B is NOT needed when the value is consumed fresh every time — in `layoutSubviews`, `drawRect:`, or a method called on-demand. See [Invalidation Analysis](#invalidation-analysis-mandatory-for-every-displayscale-replacement).

> **Always prefer `registerForTraitChanges` over overriding `traitCollectionDidChange:` — even when older code or older docs use the older method.** `traitCollectionDidChange:` is deprecated in iOS 17+, and `registerForTraitChanges([UITraitDisplayScale.self])` (or `registerForTraitChanges:@[UITraitDisplayScale.class]` in ObjC) is the correct modern form. Substitute `registerForTraitChanges` whenever trait-change observation is needed, regardless of which method appears in the original code.

### Deprecate-and-forward pattern (non-view classes)

Three required pieces: (1) deprecation, (2) new overload, (3) forwarding. Same structure regardless of access level (`private`, `internal`, `public`).

**This pattern applies to ALL of the following — not just instance methods:**
- Instance methods on non-view classes
- Static/class methods (`static func`, `class func`, ObjC class methods)
- **Static computed properties** (e.g., `static var onePixel: CGFloat`) — deprecate the property, introduce a new `static func` with `traitCollection:` parameter
- **Computed properties** (e.g., `var displayScale: CGFloat`) — deprecate the property, introduce a new method with `traitCollection:` parameter
- **Protocol extensions** (e.g., `extension MyProtocol { func renderBadge() }`) — deprecate the existing method in the extension, introduce a new method with `traitCollection:` parameter
- **Free functions** — deprecate the original, introduce a new function with `traitCollection:` parameter

For static properties or protocol extensions where adding a parameter changes the API shape (property → function), that is expected and correct. The old property/method stays as the deprecated wrapper.

**Apply deprecation at the lowest method that touches the deprecated API — not every public caller.** When a chain of public methods (`renderForLight`, `renderForDark`, `renderForAuto`) all funnel into a single private helper (`_renderWithStyle:`) that is the only site touching `UIScreen.mainScreen.scale`, deprecate **the helper**. Adding a `traitCollection:` parameter to three public methods when the helper is the only one that needs it produces three times the API surface churn for the same migration. The wrapper public methods stay untouched — they pick up the new helper signature internally. Conversely, when each public caller reads `UIScreen.main.scale` directly inside its own body, deprecate each one individually — deprecate where the deprecated API actually lives.

**Swift (do NOT delete the old method when adding a new overload):**

```swift
// WRONG — old method removed, only new method left (breaks ABI for out-of-diff callers):
class ImageProcessor: NSObject {
    func generateThumbnail(for image: UIImage, traitCollection: UITraitCollection) -> UIImage {
        let scale = traitCollection.displayScale
        return processImage(image, scale: scale)
    }
    // ← old generateThumbnail(for:) was deleted — out-of-diff callers can no longer compile,
    //   and there is no deprecation signal pointing them to the new API
}

// RIGHT — full deprecate-and-forward (all three parts mandatory, OLD METHOD KEPT):
class ImageProcessor: NSObject {
    @available(*, deprecated, message: "use generateThumbnail(for:traitCollection:) instead")
    func generateThumbnail(for image: UIImage) -> UIImage {
        return generateThumbnail(for: image, traitCollection: .current)
    }

    func generateThumbnail(for image: UIImage, traitCollection: UITraitCollection) -> UIImage {
        let scale = traitCollection.displayScale
        return processImage(image, scale: scale)
    }
}
```

**Swift initializers — the old initializer must remain as a deprecated wrapper:**

```swift
// WRONG — old init removed:
class GlyphButton: UIButton {
    init(glyph: Glyph, traitCollection: UITraitCollection) { ... }
    // ← old init(glyph:) was deleted — callers that don't yet pass traitCollection break
}

// RIGHT — old init kept as deprecated wrapper:
class GlyphButton: UIButton {
    @available(*, deprecated, message: "use init(glyph:traitCollection:) instead")
    convenience init(glyph: Glyph) {
        self.init(glyph: glyph, traitCollection: .current)
    }

    init(glyph: Glyph, traitCollection: UITraitCollection) { ... }
}
```

**Objective-C:**

In headers (or above the implementation when no header exists), the old method's declaration MUST carry a real deprecation attribute — not just a comment. Use `__attribute__((deprecated("use newMethod instead")))`. A `// Deprecated:` comment alone does not generate compiler warnings for callers and is NOT sufficient.

```objc
// In ThumbnailGenerator.h — preferred default when UIKit/Availability headers are in scope:
@interface ThumbnailGenerator : NSObject
- (UIImage *)generateThumbnailForURL:(NSURL *)url __attribute__((deprecated("use generateThumbnailForURL:traitCollection: instead")));
- (UIImage *)generateThumbnailForURL:(NSURL *)url traitCollection:(UITraitCollection *)traitCollection;
@end

// In ThumbnailGenerator.m:
@implementation ThumbnailGenerator

- (UIImage *)generateThumbnailForURL:(NSURL *)url {
    return [self generateThumbnailForURL:url traitCollection:[UITraitCollection currentTraitCollection]];
}

- (UIImage *)generateThumbnailForURL:(NSURL *)url traitCollection:(UITraitCollection *)traitCollection {
    CGFloat scale = traitCollection.displayScale;
    return [self renderThumbnail:url scale:scale];
}

@end
```

For private methods declared only in the implementation file (no header), put the attribute with the implementation:

```objc
- (UIImage *)renderBadge __attribute__((deprecated("use renderBadgeWithTraitCollection: instead"))); {
    return [self renderBadgeWithTraitCollection:[UITraitCollection currentTraitCollection]];
}
```

**Objective-C class methods (`+` methods) — same pattern, not inline:**

```objc
@interface BadgeAnimationGenerator : NSObject
+ (CAAnimation *)animation __attribute__((deprecated("use animationWithTraitCollection: instead")));;
+ (CAAnimation *)animationWithTraitCollection:(UITraitCollection *)traitCollection;
@end

@implementation BadgeAnimationGenerator

+ (CAAnimation *)animation {
    return [self animationWithTraitCollection:[UITraitCollection currentTraitCollection]];
}

+ (CAAnimation *)animationWithTraitCollection:(UITraitCollection *)traitCollection {
    CGFloat scale = traitCollection.displayScale;
    // ... use scale ...
}

@end
```

**Forwarding-chain consistency:** When the new overload calls other methods on `self` or on wrapped/sub-objects, those calls must also use the `traitCollection:`-accepting version — not the deprecated version. A new method that internally calls `object.deprecatedMethod` instead of `object.deprecatedMethod(traitCollection: traitCollection)` silently ignores the passed `traitCollection`. Verify every call site within the new method's body.

### When the user names a specific replacement path

When the user explicitly names a replacement path, use it exactly — even when a closer or "more convenient" trait source is available on `self`. The user named that specific source for a reason; substituting `self.traitCollection` to save a property hop loses scene-specific information.

---

## Invalidation Analysis (mandatory for every displayScale replacement)

**THIS CHECK IS NON-NEGOTIABLE.** Every `displayScale` replacement in a UIView/UIViewController subclass must determine: **is the value cached or consumed fresh?** If cached, you must add a `registerForTraitChanges` call for `UITraitDisplayScale` — a replacement without invalidation is incomplete — the cached value goes stale on display change.

**Default assumption: registration IS required.** Only skip it when you can confirm one of the explicit exceptions below. When replacing `UIScreen.mainScreen.scale` (or `.main.scale`) with `self.traitCollection.displayScale` in code that computes a visual property (border width, image scale, constraint constant, image generation, layer property), you MUST add trait change observation. **A `displayScale` replacement that feeds a cached or stored value MUST be paired with a `registerForTraitChanges` call — this is not optional, it is a hard requirement. Without it, cached values go stale when the user moves the window between displays.** The exceptions are:
- **(a)** The code is inside a method that UIKit auto-calls on trait change: `layoutSubviews`, `drawRect:`, `updateConstraints`, `viewIsAppearing:`
- **(b)** The code is inside a private helper called exclusively from one of the above methods

If NONE of the exceptions apply, registration is required — period.

**Registration pattern — register in init/setup, specify `UITraitDisplayScale`:**

```swift
registerForTraitChanges([UITraitDisplayScale.self]) { (self: MyView, previousTraitCollection) in
    // Recalculate the cached value(s)
}
```

> **ObjC:** `[self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(typeof(self) self, UITraitCollection *previousTraitCollection) { ... }]`. Alternative: use `withAction:@selector(methodName)` when recalculation is in a separate method.

When registering for trait changes to update a cached value (layer `lineWidth`, `borderWidth`, `contentsScale`, constraint constant, ivar), the handler MUST directly recalculate that specific property. Do NOT use `setNeedsLayout` or `setNeedsDisplay` as the action — these only work if `layoutSubviews` or `drawRect:` happens to recalculate that exact property, which it usually does not. A `setNeedsLayout` that doesn't lead to recalculation of the cached value is a no-op bug.

```swift
// directly update the cached property:
registerForTraitChanges([UITraitDisplayScale.self]) { (cell: MyCell, previousTraitCollection) in
    cell.layer.borderWidth = 1.0 / cell.traitCollection.displayScale
}
```

### Quick-reference: cached vs transient

Use this checklist to decide. If ANY cached indicator is true, registration is required.

**Cached (registration required):**
- Assigned to a layer property (`contentsScale`, `borderWidth`, `rasterizationScale`, `lineWidth`)
- Assigned to a constraint constant
- Stored in an ivar or property (`_cachedScale`, `_hairlineWidth`)
- Used to generate an image that is then stored (`button.setImage(...)`, `imageView.image = ...`)
- **Used inside a method that generates images for buttons, icons, badges, snapshots, or thumbnails** — e.g., `updateThemeButtonImages`, `updateBadgeImage`, `renderAppIcon`, `generateSnapshot`. Even if the method computes fresh, its output is stored on a view or ivar. **This is the most frequently missed case — generating a scale-dependent image and setting it on a button or image view without registering for trait changes means the image goes stale when the display scale changes.** The trait change handler should call the same image-generation method.
- Inside a setup method (`init`, `viewDidLoad`, `awakeFromNib`, `configure...`, `setup...`, `update...Images`) that sets scale-dependent values on views — even if the method computes fresh, its output is stored
- Used to compute a value passed to `CGAffineTransform`, `UIBezierPath`, or drawing code called once during setup

**Transient (no registration needed):**
- Inside `layoutSubviews`, `drawRect:`, `updateConstraints`, `viewIsAppearing:` — UIKit re-calls these on trait change
- Inside a private helper that is ONLY called from one of the above methods
- Used in a local variable that doesn't escape the current scope and the method runs on-demand (not just once at setup)
- Inside a method triggered by user interaction (`@IBAction`, gesture handler) — runs fresh each time

**When in doubt, register.** A redundant registration is harmless; a missing one causes stale rendering on display changes.

### Examples: when registration IS needed

**Cached in init:**
```swift
override init(frame: CGRect) {
    super.init(frame: frame)
    separatorLine.lineWidth = 1.0 / traitCollection.displayScale
    registerForTraitChanges([UITraitDisplayScale.self]) { (self: MyView, previousTraitCollection) in
        self.separatorLine.lineWidth = 1.0 / self.traitCollection.displayScale
    }
}
```

**Cached image:**
```swift
func updateThemeButtonImages() {
    let scale = traitCollection.displayScale
    let renderer = UIGraphicsImageRenderer(size: size)
    cachedButtonImage = renderer.image { context in /* ... */ }
    button.setImage(cachedButtonImage, for: .normal)
}

// In init or setup — handler INVOKES the existing method, never duplicates its body:
registerForTraitChanges([UITraitDisplayScale.self]) { (self: MyView, previousTraitCollection) in
    self.updateThemeButtonImages()
}
```

> **Never duplicate the update method's body inline in the handler.** The handler's job is to call `updateThemeButtonImages()` — not to copy the renderer/setImage code into the handler block. Inline duplication creates two parallel implementations that drift the moment anyone fixes a bug in one. If a method like `updateThemeButtonImages` / `updateBadgeImage` / `renderAppIcon` / `configureSeparator` already exists, the handler must call it by name. ObjC equivalent: prefer `withAction:@selector(updateThemeButtonImages)` over a `withHandler:` block that re-implements the body.

---

## Pattern 2: UIScreen.main.bounds → view.bounds

**Intent:** Get available space for layout or dimensions.

Do **NOT** replace with `self.bounds` when the code is asking "how big is the display area." The local view's bounds represent its own size, not the available screen/window space.

Do **NOT** use `?? 0` or `?? .zero` as fallback for window bounds. Refactor the API to accept size as a parameter, or move to a lifecycle point where window is guaranteed.

| Context | Replacement |
|---------|-------------|
| UIView/UIViewController in `loadView` or `init` (initial frame) | `CGRectZero` / `.zero`. **Never** access `self.view` in `loadView` — causes infinite recursion. Auto Layout resizes before display. |
| UIViewController in safe lifecycle methods | `self.view.bounds` |
| UIView in safe lifecycle methods | `self.superview.bounds` |
| UIView/UIViewController in unsafe methods | Move code to `viewIsAppearing` for view controllers and `layoutSubviews` for views or later |
| Non-view class / static / free function | Add `bounds: CGRect` parameter, deprecate original |

> **`CGRectZero` is ONLY for `loadView`/`init`.** Substituting `CGRectZero` for `[UIScreen mainScreen].bounds` in any other context (instance methods past `viewDidLoad`, layout helpers, sizing computations) produces a zero-sized layout that breaks the feature. If the call site is in a safe lifecycle method, use `self.view.bounds` (view controller) or `self.superview.bounds` (view). If `view` may be nil, move the code or ask the user — but never substitute `CGRectZero` outside `loadView`/`init`.

Safe view controller methods (view hierarchy guaranteed): `viewIsAppearing`, `viewDidAppear`, `viewWillDisappear`.
Unsafe view controller methods (view may not be in a view hierarchy): `init`, `loadView`, `viewDidLoad`, `viewWillAppear`.

**Non-view class (deprecated wrapper):**

```swift
class LayoutHelper {
    @available(*, deprecated, message: "Pass bounds from the caller's window or view context")
    static func calculateOptimalWidth() -> CGFloat {
        // TODO: Modernization - Callers should pass bounds from their window/view context
        return calculateOptimalWidth(in: UIScreen.main.bounds)
    }

    static func calculateOptimalWidth(in bounds: CGRect) -> CGFloat {
        return bounds.width * 0.9
    }
}
```

> The deprecated wrapper keeps `UIScreen.main.bounds` as a temporary bridge. **Never** replace the bridge with `UIApplication.shared.connectedScenes` or other shared state references.

---

## Pattern 3: UIScreen.main.nativeScale — NO trait-collection equivalent

`nativeScale` is the physical pixel density of the hardware display; `displayScale`/`scale` is the logical scale factor (2x, 3x). There is no trait-collection equivalent — it must come from a screen object. Same applies to `nativeBounds` and `coordinateSpace`.

```swift
// Before
let nativeScale = UIScreen.main.nativeScale
// After
let nativeScale = window.windowScene.screen.nativeScale
```

**Always use `window.windowScene.screen`**, not `window.screen`. In multi-scene environments, `window.screen` may not reflect the correct display — `windowScene.screen` ensures the screen is resolved through the scene's connection to its display. This applies to **all** screen properties accessed via window: `nativeScale`, `nativeBounds`, `scale`, `bounds`, `coordinateSpace`. Using `self.view.window.screen.nativeScale` instead of `self.view.window.windowScene.screen.nativeScale` is always wrong.

---

## Pattern 4: Keyboard Notification Coordinate Space

**Intent:** Convert keyboard frame from notification using a coordinate space.

When handling keyboard notifications (`UIKeyboardWillShowNotification`, `UIKeyboardWillChangeFrameNotification`, etc.), the notification's `object` is the screen posting the notification. Use `notification.object` to get the coordinate space — **never** substitute `self.view.window.screen` or `self.view.window.windowScene.screen`.

```objc
// WRONG — indirect path, may be nil:
CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
CGRect converted = [self.view.window.screen.coordinateSpace convertRect:keyboardFrame toCoordinateSpace:self.view];

// RIGHT — notification.object IS the screen:
CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
CGRect converted = [((UIScreen *)notification.object).coordinateSpace convertRect:keyboardFrame toCoordinateSpace:self.view];
```

This is the correct approach because:
1. `notification.object` is guaranteed to be the screen — it's always available
2. `self.view.window` may be nil if the view isn't in the hierarchy yet
3. In multi-screen environments, `notification.object` is the specific screen, not necessarily the main screen

---

## Special Cases

### Free Functions and Cached Helpers

When `UIScreen.main` appears inside a free function, `dispatch_once` helper, or cached wrapper (e.g., `mainScreenScaleFactor()`, `isLargeDevice()`, `isRetina()`), the TODO belongs at the **top of the function** — not next to the UIScreen usage. The function itself is the problem. Also add a TODO at **every call site**.

```swift
// TODO: Modernization - This cached helper assumes a single screen scale. Convert callers to pass
// traitCollection.displayScale from their view/VC context. Once all callers are migrated, remove this function.
func mainScreenScaleFactor() -> CGFloat {
    // ... cached dispatch_once returning UIScreen.main.scale
}

// At each call site:
// TODO: Modernization - Replace mainScreenScaleFactor() with self.traitCollection.displayScale
self.layer.contentsScale = mainScreenScaleFactor()
```

For device-type cached helpers (`isLargeDevice()`, `isCompactDevice()`): the TODO must explain that with flexible windowing and iPhone Mirroring, cached screen-size checks no longer reflect the active window's dimensions. Call sites should use size classes or window bounds.

### Notification Observers

When migrating `UIScreen.mainScreen` in notification observers, the TODO must note that the screen can change when a window moves between displays. The observation needs to track screen changes and re-subscribe.

```objc
// TODO: Modernization - UIScreen.mainScreen assumes a fixed screen. When a window moves between
// displays, the screen changes. Track the window's current screen, observe brightness on that
// screen, and re-subscribe when the screen changes (e.g., via windowScene.screen updates).
[[NSNotificationCenter defaultCenter] addObserver:self
    selector:@selector(brightnessChanged:)
    name:UIScreenBrightnessDidChangeNotification
    object:UIScreen.mainScreen];
```

### Fallback Paths

When code already has `self.window.screen ?: UIScreen.mainScreen`, keep the window-based access (correct path). Only address the fallback:

```objc
// TODO: Modernization - The UIScreen.mainScreen fallback assumes a single display. Consider
// what should happen when self.window is nil (e.g., return early or defer until window is set).
UIScreen *screen = self.window.screen ?: UIScreen.mainScreen;
```

When code already has `self.traitCollection.displayScale` with a `UIScreen.mainScreen.scale` fallback (e.g., `self.traitCollection.displayScale ?: UIScreen.mainScreen.scale`), **remove the entire fallback and use just `self.traitCollection.displayScale`**. The fallback is not needed as local trait collections provide their own fallback value.

```objc
// Before — ternary fallback:
CGFloat scale = self.traitCollection.displayScale ?: UIScreen.mainScreen.scale;

// RIGHT — remove fallback entirely:
CGFloat scale = self.traitCollection.displayScale;
```

When removing a UIScreen fallback where `self.traitCollection` is available, remove the entire fallback — do NOT substitute `1.0`, `?: 1`, or any other literal or invented value. If the original code was `self.traitCollection.displayScale ?: UIScreen.mainScreen.scale`, the correct replacement is `self.traitCollection.displayScale` — not `self.traitCollection.displayScale ?: 1`. The replacement must not introduce a fallback that was not present in the original non-UIScreen code path.

**Magic-number substitution is forbidden across the board.** When the original fallback is guarding something other than scale (e.g., a layout constant, a default width, a layout-driven offset), do NOT collapse the expression by substituting an invented literal for the screen-derived value. Examples of forbidden replacements:

```objc
// WRONG — invented magic number replaces the screen-derived value:
// Original: CGFloat width = useFullWidth ? [UIScreen mainScreen].bounds.size.width : 262.f;
CGFloat width = useFullWidth ? 262.f : 262.f;  // ← magic number invented to remove UIScreen

// WRONG — CGRectZero substituted for screen bounds outside loadView/init:
// Original: CGRect frame = [UIScreen mainScreen].bounds;
CGRect frame = CGRectZero;  // ← only safe in loadView/init; produces zero-sized layout elsewhere

// RIGHT — preserve the surrounding control structure with the correct context:
CGFloat width = useFullWidth ? self.view.window.bounds.size.width : 262.f;
```

If the surrounding code was using the screen as a way to get "available space," the correct replacement is `self.view.bounds` in view controllers and `self.superview.bounds` in views. If you genuinely cannot determine a safe replacement, ask the user — never substitute a magic number to make the deprecation go away.

When the original code has a ternary where **both branches compute the same semantic value** (display scale) via different accessors — e.g., `self.window.screen ? self.window.screen.scale : UIScreen.mainScreen.scale` — and `self.traitCollection.displayScale` provides that same value correctly, simplify the entire expression to `self.traitCollection.displayScale`. The ternary's purpose was to avoid the UIScreen fallback when a better source was available; `traitCollection.displayScale` serves that purpose directly without the nil-check.

**Important distinction:** This full-expression simplification applies only when both branches compute the **same value** (e.g., both get display scale). When the primary path computes a **different value** or uses a different public API (e.g., `window.screen.nativeScale` vs `UIScreen.mainScreen.scale`), preserve the primary path and only replace the UIScreen fallback.

### UIWindow Initialization

Replace `UIWindow(frame: UIScreen.main.bounds)` **only** when a `windowScene` is locally available. Otherwise add a TODO — never fetch from `connectedScenes`.

```swift
// windowScene in scope → safe to replace
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: windowScene)
}

// windowScene not available → add TODO
// TODO: Modernization - Replace with UIWindow(windowScene:) by accepting a UIWindowScene parameter
// or moving initialization to scene(_:willConnectTo:options:).
private let window: UIWindow = UIWindow(frame: UIScreen.main.bounds)
```

### SwiftUI

Replace `UIScreen.main.bounds` with `GeometryReader`. For display scale, use `@Environment(\.displayScale)`. If GeometryReader adoption is too complex, add a TODO.

```swift
// In a SwiftUI View struct:
@Environment(\.displayScale) private var displayScale
// ... in body:
imgRenderer.scale = displayScale
```

### UIGraphicsImageRendererFormat(for: UIScreen.main.traitCollection)

This pattern passes a `traitCollection` to a format initializer. **Never remove the `for:` argument — always pass a trait collection through it.**

Apply the full deprecate-and-forward pattern to the enclosing method so callers can pass the correct trait collection:

```swift
// Deprecate-and-forward on the enclosing method:
@available(*, deprecated, message: "use renderBadge(traitCollection:) instead")
func renderBadge() -> UIImage {
    return renderBadge(traitCollection: .current)
}

func renderBadge(traitCollection: UITraitCollection) -> UIImage {
    let format = UIGraphicsImageRendererFormat(for: traitCollection)
    // ...
}
```

```objc
// ObjC equivalent (real deprecation attribute on the declaration — prefer API_DEPRECATED_WITH_REPLACEMENT):
- (UIImage *)renderBadge __attribute__((deprecated("use renderBadgeWithTraitCollection: instead")));
- (UIImage *)renderBadgeWithTraitCollection:(UITraitCollection *)traitCollection;

// In the implementation:
- (UIImage *)renderBadge {
    return [self renderBadgeWithTraitCollection:[UITraitCollection currentTraitCollection]];
}

- (UIImage *)renderBadgeWithTraitCollection:(UITraitCollection *)traitCollection {
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] initForTraitCollection:traitCollection];
    // ...
}
```

This applies even to `private` methods — the deprecation signals intent and enables future callers to pass the correct trait collection.

### Call-Chain Propagation

When adding a `traitCollection` parameter to method A, check callers. If a caller also lacks a local trait collection (non-view class), apply the same deprecate-and-forward pattern. Repeat until the chain reaches a UIView/UIViewController (`self.traitCollection`).

---

## Analysis

In addition to the generic context read described in `SKILL.md` Phase 2:

- **Cached vs on-demand** — if `displayScale` is stored in an ivar/property/constraint/layer during init/setup, a `registerForTraitChanges` call for `UITraitDisplayScale` is needed (see [Invalidation Analysis](#invalidation-analysis-mandatory-for-every-displayscale-replacement) above).

## Implementation Gates

Before editing any line, answer these five gate questions:

1. **SwiftUI context?** Is this inside a `struct` conforming to `View`?
   - YES → Use `@Environment(\.displayScale)` for scale, `GeometryReader` for bounds.
   - NO → Continue to question 2. **Never introduce SwiftUI patterns (`@Environment(\.displayScale)`, `GeometryReader`) into a `UIView` or `UIViewController` subclass.** Use `self.traitCollection.displayScale` — the UIKit API — even if the project also contains SwiftUI code.
2. **Cached value?** Is the replaced value stored in a layer property, constraint, ivar, image, or button image? Or does the replacement appear inside a setup method that sets images on views (e.g., `updateThemeButtonImages`, `updateBadgeImage`, `renderAppIcon`)? Or inside `init`/`viewDidLoad`/`awakeFromNib`/`configure`/`setup` where the computed value is stored and never recomputed? Or has the user explicitly asked you to register for trait changes? **Use the [cached-vs-transient quick-reference](#quick-reference-cached-vs-transient) to decide.**
   - YES → You MUST add a `registerForTraitChanges([UITraitDisplayScale.self])` call **with either a `withHandler:` block or a `withAction:` selector**. A bare `registerForTraitChanges` with only a trait list and no handler is a compile error. A diff without registration is incomplete — the cached value will go stale on display change. **The inline API swap alone is insufficient for cached values — it only fixes the initial computation but breaks when the user moves between displays with different scales.** See [Invalidation Analysis](#invalidation-analysis-mandatory-for-every-displayscale-replacement) for cached-value indicators. **This is the most commonly missed check — verify it for every file. When in doubt, register — a redundant registration is harmless, a missing one causes stale rendering.**
   - NO → Skip the override.

   **Common blind spot:** Methods named `update*Images`, `update*Image`, `render*`, `generate*`, `createSnapshot*` that produce scale-dependent images and set them on views. Even though these methods compute fresh values, their outputs are stored (on buttons, image views, ivars). If called from init/viewDidLoad, you MUST register for trait changes and re-call the method in the handler. This is the most commonly missed pattern. **A replacement that swaps the API call but omits `registerForTraitChanges` for a cached value is incomplete — even if the inline replacement is correct, the cached output goes stale. The two parts (API swap + registration) are inseparable for cached values.**
3. **View or non-view class?** Does this class inherit from UIView or UIViewController?
   - YES, **instance method** → use `self.traitCollection.displayScale`
   - YES, **but class method or static method** → Apply step 5 (deprecate-and-forward).
   - NO, **but method already receives a `traitCollection:` parameter** → use `traitCollection.displayScale` inside the method body. No deprecation needed — the caller already provides the trait collection.
   - NO, but view/VC reachable via property/parameter → use that object's `.traitCollection.displayScale`. **Always prefer the most local source.** If the method receives a view or view controller parameter, use its `.traitCollection.displayScale`. Prefer a direct property over a multi-hop chain (3+ property accesses).
   - NO, and no view/VC reachable → apply the [deprecate-and-forward pattern](#deprecate-and-forward-pattern-non-view-classes) (new overload + deprecation + forwarding). **Both ObjC and Swift — there is no exception. This is mandatory: an inline replacement in a non-view class is always wrong — apply the full three-part pattern instead.** **This is the most common mistake in Swift files:** create a new method overload with `traitCollection: UITraitCollection`, deprecate the old method, and have the old method forward to the new one. Classes named `*Provider`, `*Downloader`, `*Manager`, `*ViewModel`, `*Processor`, `*Helper`, `*Generator`, `*Bridge`, `*Source`, `*DataProvider` are almost never view subclasses. The new overload must accept `traitCollection: UITraitCollection` (not `displayScale: CGFloat`).
4. **Dead code?** Is this inside `#if 0`/`#endif` or `#if false`? → Do not modify, modernize, or replace code within the dead block. The code was already dead; modernizing it is pointless.
5. **Different deprecation?** Before editing a line, verify it contains the target API (`UIScreen.main`/`UIScreen.mainScreen`). If the line instead contains `interfaceOrientation`, `UIDevice.current.orientation`, `UIInterfaceOrientationIsLandscape`, `UIInterfaceOrientationIsPortrait`, `statusBarOrientation`, `verticalSizeClass`, `horizontalSizeClass`, or any other deprecation — **do not touch it**. Each task is independent. This is the #1 source of out-of-scope changes. Even if the deprecated line is adjacent to or interleaved with UIScreen lines, leave it for its own task. **This applies per-line: read the original line before writing the replacement. If the original line does not contain the target API string, your edit is out of scope — revert it immediately.**

## Implementation Rules

1. Preserve code style and formatting. Handle both Swift and Objective-C.
2. **Scope rule:** Only modify lines containing the target deprecated API. If a line in your diff does not contain the target API in the original, the change is out of scope — revert it. Do not touch other deprecations, reformat code, or fix unrelated issues. **Cross-task contamination is an issue:** when working on UIScreen replacements, do NOT also fix `interfaceOrientation`, `UIDevice.current.orientation`, `self.interfaceOrientation`, `UIInterfaceOrientationIsLandscape`, `UIInterfaceOrientationIsPortrait`, `verticalSizeClass`/`horizontalSizeClass` conversions, landscape detection logic, or other deprecations that appear nearby in the same file. Each task in the Task Registry is independent. Even if you see an obvious modernization opportunity on an adjacent line, leave it alone. **Concrete example of a wrong change:** Replacing `UIInterfaceOrientationIsLandscape(self.interfaceOrientation)` with a `verticalSizeClass == .compact` check while doing UIScreen work — this is an orientation modernization, not a UIScreen modernization, and must not be included. **Only make changes that are directly covered by the active task. Do not make additional "bonus" fixes to nearby code, even if they address related deprecations. A diff that touches lines not containing the target API is out of scope.**
3. **Invalidation rule:** When the user explicitly asks to register for trait changes — add it. When the user is general — determine if the value is cached (see gate question 2). If cached, add `registerForTraitChanges([UITraitDisplayScale.self])` with a handler that recalculates. If consumed fresh, skip. **Always use `registerForTraitChanges` — even when the original code uses `traitCollectionDidChange:`.** `traitCollectionDidChange:` is deprecated in iOS 17+ and the modern API is the recommended form. Register for the specific trait class (e.g., `UITraitDisplayScale`) rather than checking all trait changes. Always use a `withHandler:` block that directly sets the property, or a `withAction:` selector pointing to a method that directly recalculates it.
4. **Replacement path rule:** When the user provides an explicit replacement expression, use it exactly. Do not substitute a generic fallback or shorter path. The named path reflects the correct scene/display context — substituting it loses that context. **Method parameters always take priority.** When a method parameter directly provides the needed value (e.g., a `CALayer *layer` parameter has `layer.contentsScale`, a view parameter has `.traitCollection.displayScale`), use the parameter — even if a longer path through `self` would also work. The parameter is the most local, most reliable source. A method that ignores an available `layer` parameter and instead navigates through `self.someController.someView.traitCollection.displayScale` is always wrong — use `layer.contentsScale`. When a notification's `object` provides the needed value (e.g., `notification.object` is the screen for `UIScreenBrightnessDidChangeNotification`, or `notification.object.coordinateSpace` for keyboard notifications), use `notification.object` — never substitute `self.view.window.screen` or another indirect path. **If the user names a specific view's trait collection, that path is mandatory — not optional.**
5. **Parameter type rule:** When introducing a new method overload for deprecate-and-forward, the parameter must be `traitCollection: UITraitCollection` (Swift) or `traitCollection:(UITraitCollection *)traitCollection` (ObjC). Never use `displayScale: CGFloat` or `scale: CGFloat`. Extract `.displayScale` inside the new method body. This ensures callers pass the full trait collection, enabling future use of other traits without another API change. **User-instruction exception:** when the user explicitly asks for a different parameter (e.g., `scale: CGFloat`), use exactly the parameter name, type, and position they specify. **Parameter position:** when the user is general, place the new parameter at the end (before any trailing closure). When the user specifies a position, use that position exactly — do NOT move it to the end.
7. **ObjC deprecation attribute rule:** In Objective-C, every deprecate-and-forward old method must carry a real deprecation **attribute** on its declaration — not just a comment. **Default to `__attribute__((deprecated("use <newMethodName> instead")));`**. **User-instruction exception:** when the user explicitly asks for a particular attribute, follow that — the default only applies when the user is general. The attribute belongs in the header where the method is declared; for private methods without a header, place it at the implementation. A `// Deprecated:` comment alone does NOT produce compiler warnings for callers and is insufficient. Apply this consistently to every ObjC deprecate-and-forward in a file.
8. **All occurrences rule:** Replace ALL `UIScreen.main`/`UIScreen.mainScreen` occurrences in a file, including those inside utility function/macro calls (e.g., `UIRoundToScreenScale(UIScreen.mainScreen.scale, ...)` — replace the `UIScreen.mainScreen.scale` argument with `self.traitCollection.displayScale`). Leaving some occurrences unchanged while fixing others is a partial fix and leaves the file half-migrated.
9. **Ternary preservation rule:** When existing code has a ternary with a non-UIScreen primary path, check whether both branches compute the **same semantic value** (e.g., both get display scale). If yes and `self.traitCollection.displayScale` provides that value, simplify the entire expression. If the primary path computes a **different value** or uses a valid public API for a different purpose, only replace the `UIScreen` fallback branch — do not remove or restructure the primary path.
10. **Utility function rule:** When existing code uses utility functions that wrap `UIScreen.main.scale` (e.g., `UIRoundToScreenScale(value, UIScreen.mainScreen.scale)`, `UIRoundToScale`), prefer replacing the `UIScreen` argument with the modern equivalent while keeping the utility function call — do not reimplement the utility function's logic inline. For example, replace `UIRoundToScreenScale(value, UIScreen.mainScreen.scale)` with `UIRoundToViewScale(value, self.view)` or `UIRoundToScale(value, self.traitCollection.displayScale)` rather than manually inlining `(scale > 0) ? round(value * scale) / scale : value`.
11. **Forwarding-chain consistency rule:** When a new method overload (from deprecate-and-forward) calls other methods on `self` or on wrapped/sub-objects, those calls must also use the `traitCollection:`-accepting version — not the deprecated version. A new method that internally calls the deprecated API on a sub-object silently ignores the passed `traitCollection`. This is a correctness bug. **Verify ALL code paths:** if the new method has branches (if/else, switch, guard/else, optional binding), check EVERY branch — not just the happy path. A common bug is correctly using `traitCollection` in one branch but falling back to the deprecated path in another.
12. **Existing parameter preservation rule:** When a method already has a parameter that provides scale information (e.g., `displayScale: CGFloat`, `scale: CGFloat`), do NOT change that parameter's type to `UITraitCollection`. Replace the `UIScreen` usage inside the method body using the existing parameter. Only add a new `traitCollection: UITraitCollection` parameter when introducing a NEW method overload where the original method had no way to receive the value. Changing an existing `CGFloat` parameter to `UITraitCollection` is a broader API change than needed and breaks callers.

13. **Defensive-guard preservation rule:** Leave unrelated defensive logic that wraps the screen access intact. `respondsToSelector:` checks, nil-window guards, `#available`/`@available` version checks, and similar conditionals exist for reasons unrelated to the deprecation — modernize only the `UIScreen.mainScreen` reference, not the conditional that wraps it. **Failure pattern:** an `if/else` with a `respondsToSelector:` check on the primary path and a UIScreen fallback on the else branch — replace the UIScreen fallback only, not the entire if/else. **Multiple constructor paths (e.g., `initWithFrame:` AND `awakeFromNib`) that each register handlers must NOT be consolidated** — both code paths exist for object-creation differences (programmatic vs. nib loading) that the modernization has no opinion about.

## Post-file Checklist

Verify before moving to the next file:

- [ ] Cached value (layer property, constraint, ivar, stored image, button image, setup/image-generation method output) → `registerForTraitChanges` present? Both API swap and registration are required for cached values — independent of any deprecate-and-forward also applied in this file.
- [ ] `registerForTraitChanges` present → has `withHandler:` or `withAction:`? In a one-time setup method (not `layoutSubviews`)? Handler directly recalculates the property (not `setNeedsLayout` as proxy)?
- [ ] `loadView` context → `CGRectZero`/`.zero` for initial frame? Never access `self.view` (infinite recursion crash).
- [ ] View/VC instance method → `self.traitCollection`?
- [ ] Class method or static method → deprecate-and-forward (not `self.traitCollection`)?
- [ ] `CALayer *layer` parameter available → `layer.contentsScale`? Applies even in non-view classes.
- [ ] Non-view class → full deprecate-and-forward (not inline)? Applies to `*Provider`, `*Manager`, `*Helper`, `*Generator`, `*Bridge`, `*Source`, `*DataProvider`, static computed properties, protocol extensions. Verify: NEW method with `traitCollection: UITraitCollection`, `@available(*, deprecated)` on old, deprecated wrapper forwards to the new overload. Applies regardless of project context or class name. **Exception:** `private`/`fileprivate`/`static` symbol with all callers in the same file → use the smallest-edit rule (modify signature in place, update in-file callers) per the file-local helper exception in [Pattern 1](#pattern-1-uiscreenmainscale--traitcollectiondisplayscale), step 5.
- [ ] Old method/initializer KEPT as deprecated wrapper (not deleted)? When adding a new overload via deprecate-and-forward, the original declaration must remain in the file with the deprecation attribute. Removing it breaks ABI for out-of-diff callers and strips the migration signal.
- [ ] Unrelated guards preserved? `respondsToSelector:` checks, nil-window guards, `#available`/`@available` checks, multiple constructor paths (`initWithFrame:` AND `awakeFromNib`) — all left intact unless the user explicitly asks to remove them.
- [ ] ObjC deprecate-and-forward → real `__attribute__((deprecated(...)))` attribute on the declaration (not just a `// Deprecated:` comment)?
- [ ] Deprecate-and-forward applied → are in-diff callers with a view in scope updated to call the new overload directly with `self.traitCollection` (not still on the deprecated wrapper)?
- [ ] No whitespace-only edits? Every changed line is part of the targeted replacement or a structural part of the new pattern.
- [ ] Nil-screen *object* fallback removed (`screen ?: [UIScreen mainScreen]`) → either kept an equivalent guard or added a TODO surfacing the new "non-nil screen assumed" behavior?
- [ ] Existing `CGFloat` scale parameter preserved (not changed to `UITraitCollection`)?
- [ ] Multiple methods need deprecate-and-forward → applied to ALL consistently?
- [ ] `UIGraphicsImageRendererFormat(for:)` → deprecate-and-forward on **enclosing method** (not inline swap, not removing `for:` argument)?
- [ ] Screen via window uses `window.windowScene.screen`?
- [ ] **If the file already has an `update*` / `render*` / `configure*` method that produces the cached value, the trait-change handler invokes it by name (not duplicating its body inline)?**
- [ ] **Deprecation applied at the lowest method that touches the deprecated API (helper, when several public callers funnel into one) — not duplicated across every public caller?**
- [ ] **New overload's parameter is `traitCollection: UITraitCollection`, NOT a scalar (`displayScale: CGFloat`, `contentsScale: CGFloat`, `scale: CGFloat`)?** Use a scalar only when the user explicitly asks for one.
- [ ] **Edited line actually contains the active task's target API at the intended site (not a nearby line that "looks similar," e.g., a different `UIScreen.main.*` accessor or a different observer registration)?**
- [ ] No unrelated changes? Every changed line must contain `UIScreen` in the original.
- [ ] Bounds consistency? If multiple `UIScreen.mainScreen.bounds` replacements, all use same target.
- [ ] Control flow preserved? Branch count before = branch count after.
- [ ] No dead code modified?
- [ ] Forwarding chain correct? New overload doesn't call deprecated APIs internally — check ALL branches, not just the happy path.

**Atomic completeness check (most critical — verify this last):**
- [ ] If this file needed BOTH an API swap AND `registerForTraitChanges` → are BOTH present in the diff? (Not "I'll add it later" — both must be in this diff.)
- [ ] If this file needed deprecate-and-forward → does the diff contain all THREE parts (deprecation + new overload + forwarding)? An inline replacement when the pattern calls for method extraction is always wrong.

## Final Verification

In addition to the generic file-coverage audit in `SKILL.md` Phase 5:

1. **Multi-part completeness audit:** For every file where you applied an API replacement, verify:
   - If the value is cached → does the diff also include `registerForTraitChanges`? If not, add it now. The API swap alone is never sufficient for cached values.
   - If the active task calls for deprecate-and-forward → does the diff contain all three parts (deprecation annotation + new overload + forwarding)? If you only did an inline replacement, redo it with the full pattern.
   - Both requirements (trait registration AND deprecate-and-forward) may apply to the same file independently. Completing one does not satisfy the other.

2. **Forwarding correctness audit:** For every new method overload you created, verify that ALL code paths within the new method use the passed `traitCollection` parameter — not the deprecated overload, not `UIScreen.main`. If any branch ignores the parameter, fix it now.

---

## API Reference

- [TN3187: Architecting your app for multiple windows](https://developer.apple.com/documentation/uikit/app_and_environment/scenes)
- [TN3124: Coordinate spaces and coordinate conversion](https://developer.apple.com/documentation/uikit/uicoordinatespace)
