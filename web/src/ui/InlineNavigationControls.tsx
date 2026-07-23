import { useRouter, type RouterHistory } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useSyncExternalStore } from "react"
import { colors } from "../styles/tokens.stylex"
import { Icon } from "./Icon"
import { InlineIconButton } from "./InlineIconButton"

type HistoryPosition = {
  index: number
  furthestIndex: number
}

type HistoryPositionTracker = {
  getSnapshot: () => HistoryPosition
  subscribe: (listener: () => void) => () => void
}

const historyTrackers = new WeakMap<RouterHistory, HistoryPositionTracker>()

const historyIndex = (history: RouterHistory) =>
  history.location.state.__TSR_index ?? 0

const trackerForHistory = (history: RouterHistory) => {
  const existing = historyTrackers.get(history)
  if (existing) return existing

  const listeners = new Set<() => void>()
  const initialIndex = historyIndex(history)
  let snapshot: HistoryPosition = {
    index: initialIndex,
    furthestIndex: initialIndex,
  }
  history.subscribe(({ action, location }) => {
    const index = location.state.__TSR_index ?? 0
    const furthestIndex =
      action.type === "PUSH"
        ? index
        : Math.max(snapshot.furthestIndex, index)
    if (
      snapshot.index === index &&
      snapshot.furthestIndex === furthestIndex
    ) {
      return
    }
    snapshot = { index, furthestIndex }
    for (const listener of listeners) listener()
  })
  const tracker: HistoryPositionTracker = {
    getSnapshot: () => snapshot,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
  historyTrackers.set(history, tracker)
  return tracker
}

export function InlineNavigationControls() {
  const router = useRouter()
  const tracker = trackerForHistory(router.history)
  const position = useSyncExternalStore(
    tracker.subscribe,
    tracker.getSnapshot,
    tracker.getSnapshot,
  )
  const canGoBack = router.history.canGoBack()
  const canGoForward = position.index < position.furthestIndex

  return (
    <span aria-label="Navigation" role="group" {...stylex.props(styles.root)}>
      <InlineIconButton
        aria-label="Back"
        title="Back"
        size="small"
        disabled={!canGoBack}
        onClick={() => router.history.back()}
      >
        <Icon name="back" size={17} />
      </InlineIconButton>
      <span aria-hidden="true" {...stylex.props(styles.separator)} />
      <InlineIconButton
        aria-label="Forward"
        title="Forward"
        size="small"
        disabled={!canGoForward}
        onClick={() => router.history.forward()}
      >
        <Icon name="forward" size={17} />
      </InlineIconButton>
    </span>
  )
}

const styles = stylex.create({
  root: {
    height: 30,
    display: "inline-flex",
    alignItems: "center",
    flexShrink: 0,
    overflow: "hidden",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 15,
    backgroundColor: colors.control,
    WebkitAppRegion: "no-drag",
  },
  separator: {
    width: 1,
    height: 16,
    backgroundColor: colors.separator,
  },
})
