/**
 * Every number the timeline uses, with where it comes from. "Mac" is the
 * native client in `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`
 * unless another file is named. Values are in CSS pixels, milliseconds or
 * seconds as named. The guide calls these start values: tune them with
 * measurements and record the change in `web/docs/decisions.md`.
 */

// ---------------------------------------------------------------------------
// Following latest

/** A reader scrolling back down reattaches inside this distance from the bottom. Mac: `bottomFollowZone` = 44 pt. */
export const FOLLOW_ZONE_PX = 44

/**
 * Only a list resting within this distance of the bottom stays pinned through
 * size changes. Mac: `exactBottomTolerance` = 1 pt (AppKit snaps the scroll
 * limit to the pixel grid).
 */
export const EXACT_BOTTOM_PX = 1

// ---------------------------------------------------------------------------
// Compensation

/**
 * Corrections smaller than this are not written to the scroll offset. The
 * remainder is kept, so skipped corrections never accumulate. Mac:
 * `UnreadLineGeometry.tolerance` = 0.5 pt and `MessageListViewport.restore`.
 */
export const MIN_CORRECTION_PX = 0.5

/**
 * The scroll offset the controller last wrote is trusted over the one the
 * host reads back when the two differ by no more than this: engines round
 * `scrollTop` to device pixels, and reading the rounded value back would lose
 * the fraction on every correction. Web-only; no Mac equivalent.
 */
export const OFFSET_ROUNDING_TOLERANCE_PX = 1

// ---------------------------------------------------------------------------
// Scrolling state

/**
 * User scrolling ends this long after the last input or scroll event when the
 * host has no `scrollend`. noor0 rail: scroll-end debounce 150 ms. (Mac uses
 * NSScrollView's live-scroll end notification instead.)
 */
export const SCROLL_IDLE_MS = 150

// ---------------------------------------------------------------------------
// Window

/** Initial window rows: `viewportHeight / 24 + 30`. Mac: `MessagesProgressiveViewModel.defaultInitialLimit` (on screen height). */
export const INITIAL_ROWS_PX_PER_ROW = 24
export const INITIAL_ROWS_BASE = 30
/** Rows when the viewport has no height yet. Mac: `defaultInitialLimit` fallback = 60. */
export const INITIAL_ROWS_FALLBACK = 60

/** Ask for older or newer rows within this many viewports of an edge. Mac: `handleBoundsChange`, `currentScrollOffset < viewportSize.height`. */
export const LOAD_MORE_VIEWPORTS = 1

/** Trim the rendered window once it holds more rows than this. Guide start value (`timeline-and-composer.md`, Window); the Mac table does not trim. */
export const TRIM_ABOVE_ROWS = 300
/** Trim down to this many rows around the viewport. Guide start value. */
export const TRIM_TO_ROWS = 200

// ---------------------------------------------------------------------------
// Opening and unread

/** Rows read on each side of the last read message. Mac: `ChatUnreadOpening.windowLimit` = 88, 44 per side. */
export const UNREAD_WINDOW_SIDE_ROWS = 44

/** The spinner over a hidden list waiting for unread history appears only after this. Mac: `beginUnreadFetchIfNeeded`, 0.25 s. */
export const UNREAD_SPINNER_DELAY_MS = 250

/** Fade-in of a list revealed after placement, for the view. Mac: `revealListAfterLayout`, 0.2 s ease-out. */
export const REVEAL_FADE_MS = 200

// ---------------------------------------------------------------------------
// Jumps

/** A jump farther than this many viewports travels in two phases. Mac: `scrollToMessage`, `distance > viewportHeight * 2`. */
export const FAR_JUMP_VIEWPORTS = 2
/** Far jump phase 1: ease in to half a viewport short of the target. Mac: 0.3 s, `.easeIn`. */
export const FAR_JUMP_PHASE1_MS = 300
/** Far jump phase 2: ease out onto the target. Mac: 0.4 s, `.easeOut`. */
export const FAR_JUMP_PHASE2_MS = 400
/** A near jump is one animation. Mac: 0.4 s, `.easeInEaseOut`. */
export const NEAR_JUMP_MS = 400

// ---------------------------------------------------------------------------
// Grouping

/** Two messages group only if at most this many seconds apart. Mac: `canGroup`, `gapSeconds <= 300`. */
export const GROUP_MAX_GAP_SECONDS = 300
