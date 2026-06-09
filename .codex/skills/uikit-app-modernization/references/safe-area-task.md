# Task: Safe Area Inset Modernization

## Overview

In older versions of iOS, layouts hardcoded the heights of status bars (20pt), navigation bars (44pt), tab bars (49pt), and home indicators (34pt) and used `topLayoutGuide` / `bottomLayoutGuide` to position content under bars. Modern iOS exposes these via `safeAreaInsets` / `safeAreaLayoutGuide`, which already encode the geometry of the current device, orientation, and split-view configuration. Code that hardcodes those magic numbers, that re-uses one edge's inset for the opposite edge, or that infers display geometry from inset values needs to be updated.

**Detection patterns:**

- Deprecated guides:
  - `topLayoutGuide`, `bottomLayoutGuide`
- Hardcoded bar heights used as constraint constants or in `UIEdgeInsets`:
  - Common literal values to look for: `20` (status bar), `44` (navigation bar), `64` (status + nav), `88` (status + large nav), `34` (home indicator), `49` (tab bar), `83` (tab + home indicator).
  - Patterns: `.constant = <literal>` for those values, `UIEdgeInsetsMake(<literal>, ...)`, `UIEdgeInsets(top: <literal>, ...)`.
- Symmetric / asymmetry misuse of `safeAreaInsets`:
  - The same edge accessor used on opposite anchors (e.g., `safeAreaInsets.left` applied to leading **and** trailing in a ternary or paired calculation).
  - `max(safeAreaInsets.left, safeAreaInsets.right)` applied to both sides.
  - Threshold checks like `safeAreaInsets.top > <literal>`, `safeAreaInsets.left > 0`, `safeAreaInsets.bottom > 0` used as a proxy for display geometry.
  - `UIDevice` model checks gating layout decisions.
- Layout margin / RTL gaps:
  - Writes to `layoutMargins` (UIEdgeInsets) on a view, stack view, table view, or collection view (should be `directionalLayoutMargins`).
  - `viewRespectsSystemMinimumLayoutMargins = NO` / `false` without a justifying comment.
- Manual frame math:
  - Hardcoded numeric offsets in `layoutSubviews`, `viewWillLayoutSubviews`, or manual `frame =` assignments that should derive from `safeAreaInsets`.

For each candidate, read the surrounding context to confirm the literal really is a bar offset (not a font size, animation duration, etc.) before treating it as a fix target. The rules below describe the fix for each confirmed candidate.

---

## Rules

You are updating a UIKit codebase to properly account for modern layout margins and safe areas. Audit the code and apply the following changes:

## 1. Replace deprecated layout guides

- Replace all uses of `topLayoutGuide` and `bottomLayoutGuide` with `view.safeAreaLayoutGuide`. For example:
    - `topLayoutGuide.bottomAnchor` → `safeAreaLayoutGuide.topAnchor`
    - `bottomLayoutGuide.topAnchor` → `safeAreaLayoutGuide.bottomAnchor`

## 2. Fix hardcoded status bar / navigation bar offsets

- Remove hardcoded values like `20`, `44`, `64`, `88`, `34`, `49`, `83` used as top/bottom insets to account for status bars, navigation bars, tab bars, or home indicators. Replace with constraints to `safeAreaLayoutGuide` or use `safeAreaInsets` when doing manual layout in `layoutSubviews`.

## 3. Constrain to safe area instead of superview edges

- When a view should not underlap bars or device insets, pin to `safeAreaLayoutGuide` anchors instead of the superview's edges.
- When a view SHOULD extend under bars (e.g., background fills, scroll views), pin edges to superview but use `contentInsetAdjustmentBehavior = .automatic` or set `contentInset` from `safeAreaInsets` as appropriate.

## 4. Use directional layout margins

- Replace `layoutMargins` (UIEdgeInsets) with `directionalLayoutMargins` (NSDirectionalEdgeInsets) to support RTL layouts.
- Where views should respect the system minimum margins, ensure `viewRespectsSystemMinimumLayoutMargins` is not set to `false` without good reason.
- Use `layoutMarginsGuide` for content that should be inset from the edges by the system-standard amount.

## 5. Handle `safeAreaInsets` in manual layout

- In any `layoutSubviews` or manual frame calculation, replace hardcoded inset values with `safeAreaInsets` from the relevant view.
- In `viewSafeAreaInsetsDidChange`, trigger layout updates if needed.

## 6. Remove assumptions about safe area inset symmetry and hardware placement

- Do NOT assume left and right safe area insets are equal. On devices in landscape with a sensor housing (e.g., iPhone with Dynamic Island), only one side has a nonzero horizontal inset. Apply each edge's inset independently using `safeAreaInsets.left` and `safeAreaInsets.right` (or the leading/trailing anchors of `safeAreaLayoutGuide`).
- Do NOT assume top and bottom safe area insets are equal or that one can be derived from the other. The top inset (status bar, Dynamic Island) and the bottom inset (home indicator) are independent values that vary by device and orientation.
- Do NOT assume hardware features like the notch, Dynamic Island, or camera housing are at a fixed edge or position. These features move depending on device orientation and vary across device generations. Code should never check for a specific device model or orientation to decide which edge has the sensor housing — rely solely on `safeAreaInsets` and `safeAreaLayoutGuide`, which already encode the correct geometry for the current device and orientation.
- Watch for patterns like:
    - Using `safeAreaInsets.top` for both top and bottom
    - Using `safeAreaInsets.left` for both left and right
    - Calculating a single "horizontal inset" as `safeAreaInsets.left` and applying it to both sides
    - Using `max(safeAreaInsets.left, safeAreaInsets.right)` for both sides (unless the design explicitly requires symmetric padding)
    - Checking device model strings or `UIDevice` to infer which edges have hardware obstructions
    - Assuming the notch/Dynamic Island is always on the top edge
- Each edge must read its own corresponding inset value.

## 7. UIScrollView considerations

- Prefer `contentInsetAdjustmentBehavior = .automatic` over manually setting `contentInset` from safe area values.
- When using `adjustedContentInset`, do not also manually add safe area insets (this double-insets).

## 8. Preserve existing visual behavior

- Do NOT change layouts that are intentionally edge-to-edge (backgrounds, media players, maps). Only adjust content that should respect safe areas.
- When in doubt, match the existing visual behavior — the goal is correctness on modern devices, not a redesign.

## Constraints

- Do not introduce SwiftUI or any new dependencies.
- Minimize diff size: make the smallest change that fixes each issue.
- If a file has no issues, do not modify it.
