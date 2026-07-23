import {
  MessageSendingStatus,
  messageWindowCursor,
  type MessageWindowCursor,
} from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import {
  compareInlineIds,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import {
  useCallback,
  forwardRef,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import {
  Virtualizer,
  type CacheSnapshot,
  type VirtualizerHandle,
} from "virtua"
import { colors } from "../styles/tokens.stylex"
import {
  MessageListController,
  shouldFollowMessageListChange,
} from "./MessageListController"
import {
  captureMessageListScrollState,
  classifyMessageListDataChange,
  isMessageListAtBottom,
  messageListChangeShiftsStart,
  messageListScrollStates,
  restoreMessageListScrollState,
} from "./MessageListScrollState"
import { MessageRow } from "./MessageRow"
import type { ChatMessageRow } from "./ChatRowListModel"
import type { InlinePeerRoute } from "~/inline/data/peer"
import { useInlineAppearancePreferences } from "~/inline/preferences/InlineAppearancePreferencesContext"
import { InlineSpinner } from "~/ui/InlineSpinner"

type PendingLayoutAnchor = {
  messageId: string
  top: number
}

const visibleMessageActions = (viewport: HTMLElement): HTMLElement[] => {
  const viewportRect = viewport.getBoundingClientRect()
  return Array.from(
    viewport.querySelectorAll<HTMLElement>("[data-inline-message-action]"),
  ).filter((action) => {
    const rect = action.getBoundingClientRect()
    return (
      rect.height > 0 &&
      rect.bottom > viewportRect.top &&
      rect.top < viewportRect.bottom
    )
  })
}

const visibleLayoutAnchor = (
  viewport: HTMLElement,
): PendingLayoutAnchor | undefined => {
  const viewportRect = viewport.getBoundingClientRect()
  let partial: PendingLayoutAnchor | undefined
  for (const row of viewport.querySelectorAll<HTMLElement>("[data-message-id]")) {
    const rect = row.getBoundingClientRect()
    if (rect.bottom <= viewportRect.top || rect.top >= viewportRect.bottom) continue
    const anchor = {
      messageId: row.dataset.messageId!,
      top: rect.top - viewportRect.top,
    }
    if (rect.top >= viewportRect.top) return anchor
    partial ??= anchor
  }
  return partial
}

export type MessageListViewHandle = {
  scrollToMessage: (messageId: string) => boolean
  scrollToBottom: () => void
}

export const MessageListView = forwardRef<MessageListViewHandle, {
  rows: ChatMessageRow[]
  loading: boolean
  loadingOlder: boolean
  loadingNewer: boolean
  hasOlder: boolean
  hasNewer: boolean
  showParticipants: boolean
  scrollStateKey: string
  onLoadOlder: (before: MessageWindowCursor) => void
  onLoadNewer: (after: MessageWindowCursor) => void
  onVisibleRangeChange?: (
    firstVisibleMessageId: MessageID,
    lastVisibleMessageId: MessageID,
  ) => void
  onFirstLayout?: () => void
  expectedInitialRowCount?: number
  onBottomStateChange?: (atBottom: boolean) => void
  unreadAfterMessageId?: MessageID
  onOpenMessage: (messageId: MessageID) => void
  onOpenReplyThread: (chatId: ChatID) => void
  onResendMessage: (messageId: MessageID) => void
  onReplyMessage: (message: ChatMessageRow) => void
  onTogglePinMessage: (message: ChatMessageRow) => void
  pinnedMessageIds?: readonly string[]
  peer: InlinePeerRoute
  currentUserId: UserID
}>(function MessageListView({
  rows,
  loading,
  loadingOlder,
  loadingNewer,
  hasOlder,
  hasNewer,
  showParticipants,
  scrollStateKey,
  onLoadOlder,
  onLoadNewer,
  onVisibleRangeChange,
  onFirstLayout,
  expectedInitialRowCount = 0,
  onBottomStateChange,
  unreadAfterMessageId,
  onOpenMessage,
  onOpenReplyThread,
  onResendMessage,
  onReplyMessage,
  onTogglePinMessage,
  pinnedMessageIds,
  peer,
  currentUserId,
}, forwardedRef) {
  const { preferences, subscribeBeforeChange } =
    useInlineAppearancePreferences()
  const messageStyle = preferences.messageStyle
  const currentLayoutSignature = useCallback(
    () => {
      if (typeof document === "undefined") {
        return `${messageStyle}:${preferences.sidebarItemSize}:server`
      }
      return `${messageStyle}:${preferences.sidebarItemSize}:` +
        `${document.documentElement.clientWidth}x` +
        `${document.documentElement.clientHeight}:` +
        `${window.devicePixelRatio}`
    },
    [messageStyle, preferences.sidebarItemSize],
  )
  const layoutSignature = currentLayoutSignature()
  const scrollRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const listRef = useRef<VirtualizerHandle>(null)
  const cancelPendingPositionOnScroll = useRef(false)
  const didPosition = useRef(false)
  const previousMessageIds = useRef<string[]>([])
  const messagesRef = useRef(rows)
  messagesRef.current = rows
  const rowCountRef = useRef(rows.length)
  rowCountRef.current = rows.length
  const itemIds = useMemo(
    () => rows.map((message) => message.id),
    [rows],
  )
  const dataChange = classifyMessageListDataChange(
    previousMessageIds.current,
    itemIds,
  )
  const slidingWindowAnchor = (() => {
    if (
      dataChange !== "window-forward" &&
      dataChange !== "window-backward"
    ) {
      return undefined
    }
    const list = listRef.current
    if (!list) return undefined
    const anchorIndex = Math.max(
      0,
      Math.min(
        previousMessageIds.current.length - 1,
        list.findItemIndex(list.scrollOffset),
      ),
    )
    const id = previousMessageIds.current[anchorIndex]
    if (id == null) return undefined
    return {
      id,
      offset:
        list.scrollOffset - list.getItemOffset(anchorIndex),
    }
  })()
  const shift = messageListChangeShiftsStart(dataChange)
  const [savedScrollState] = useState(() =>
    messageListScrollStates.get(scrollStateKey),
  )
  const [restoreTarget] = useState(() =>
    restoreMessageListScrollState(
      savedScrollState,
      itemIds,
      layoutSignature,
    ),
  )
  const [initialCache] = useState<CacheSnapshot | undefined>(() =>
    restoreTarget.mode === "exact" || restoreTarget.mode === "bottom"
      ? restoreTarget.cache
      : undefined,
  )
  const [retainInitialRange, setRetainInitialRange] = useState(
    savedScrollState == null,
  )
  const initialKeepMounted = useMemo<readonly number[]>(() => {
    if (!retainInitialRange) return []
    const count = Math.min(rows.length, 40)
    if (count === 0) return []
    const restoreIndex = (() => {
      if (restoreTarget.mode === "anchor") return restoreTarget.index
      if (restoreTarget.mode === "bottom") return rows.length - 1
      const exactAnchorId = savedScrollState?.anchorId
      const exactIndex = exactAnchorId
        ? itemIds.indexOf(exactAnchorId as ChatMessageRow["id"])
        : -1
      return exactIndex >= 0 ? exactIndex : rows.length - 1
    })()
    const desiredStart =
      restoreTarget.mode === "bottom"
        ? rows.length - count
        : restoreIndex - Math.floor(count / 4)
    const start = Math.max(
      0,
      Math.min(rows.length - count, desiredStart),
    )
    return Array.from({ length: count }, (_, index) => start + index)
  }, [
    itemIds,
    restoreTarget,
    retainInitialRange,
    rows.length,
    savedScrollState?.anchorId,
  ])
  const hasNewerRef = useRef(hasNewer)
  hasNewerRef.current = hasNewer
  const controllerRef = useRef<MessageListController | undefined>(undefined)
  controllerRef.current ??= new MessageListController({
    startsAtBottom: restoreTarget.mode === "bottom",
    hasNewer,
  })
  controllerRef.current.setHasNewer(hasNewer)
  const lastReportedBottom = useRef<boolean | undefined>(undefined)
  const onBottomStateChangeRef = useRef(onBottomStateChange)
  onBottomStateChangeRef.current = onBottomStateChange
  const highlightTimeout = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const [highlightedMessageId, setHighlightedMessageId] = useState<string>()
  const didReportFirstLayout = useRef(false)
  const didRequestMeasuredInitialPosition = useRef(false)
  const loadingRef = useRef(loading)
  loadingRef.current = loading
  const onFirstLayoutRef = useRef(onFirstLayout)
  onFirstLayoutRef.current = onFirstLayout
  const expectedInitialRowCountRef = useRef(expectedInitialRowCount)
  expectedInitialRowCountRef.current = expectedInitialRowCount
  const pendingLayoutAnchor = useRef<PendingLayoutAnchor | undefined>(undefined)

  const reportFirstLayoutIfReady = useCallback(() => {
    const viewport = scrollRef.current
    const recordReadiness = (state: string) => {
      if (viewport) viewport.dataset.inlineFirstLayout = state
    }
    if (didReportFirstLayout.current) {
      recordReadiness("reported")
      return true
    }
    if (rowCountRef.current === 0) {
      if (
        loadingRef.current ||
        expectedInitialRowCountRef.current > 0
      ) {
        recordReadiness("waiting-for-rows")
        return false
      }
    } else {
      const row = viewport?.querySelector<HTMLElement>("[data-message-id]")
      if (!row) {
        recordReadiness("waiting-for-mounted-row")
        return false
      }
      const view = row.ownerDocument.defaultView
      if (
        !view ||
        view.getComputedStyle(row).visibility === "hidden" ||
        row.getBoundingClientRect().height <= 0
      ) {
        recordReadiness("waiting-for-measured-row")
        return false
      }
      if (
        restoreTarget.mode === "bottom" &&
        !hasNewerRef.current &&
        !isMessageListAtBottom(
          viewport!.scrollHeight,
          viewport!.scrollTop,
          viewport!.clientHeight,
        )
      ) {
        if (!didRequestMeasuredInitialPosition.current) {
          // Once a real row and scroll extent exist, the browser owns the
          // authoritative physical end. A native write avoids asking Virtua
          // to resolve the same pre-measure index target a second time.
          const measuredEnd = Math.max(
            0,
            viewport!.scrollHeight - viewport!.clientHeight,
          )
          if (measuredEnd > 0) {
            didRequestMeasuredInitialPosition.current = true
            viewport!.scrollTop = measuredEnd
          }
        }
        recordReadiness("waiting-for-bottom")
        return false
      }
      if (
        restoreTarget.mode === "exact" &&
        Math.abs(
          (listRef.current?.scrollOffset ?? viewport!.scrollTop) -
            ((listRef.current?.getItemOffset(restoreTarget.index) ?? 0) +
              restoreTarget.offset),
        ) > 1.5
      ) {
        if (!didRequestMeasuredInitialPosition.current) {
          didRequestMeasuredInitialPosition.current = true
          listRef.current?.scrollToIndex(restoreTarget.index, {
            align: "start",
            offset: restoreTarget.offset,
          })
        }
        recordReadiness("waiting-for-anchor")
        return false
      }
    }
    didReportFirstLayout.current = true
    recordReadiness("reported")
    onFirstLayoutRef.current?.()
    return true
  }, [restoreTarget])

  const reportBottomState = useCallback(() => {
    const next = controllerRef.current!.logicalBottom
    if (scrollRef.current) {
      scrollRef.current.dataset.inlineLogicalBottom = String(next)
    }
    if (lastReportedBottom.current === next) return
    lastReportedBottom.current = next
    onBottomStateChangeRef.current?.(next)
  }, [])

  const readPhysicalBottom = useCallback(() => {
    const viewport = scrollRef.current
    return Boolean(
      viewport &&
        isMessageListAtBottom(
          viewport.scrollHeight,
          viewport.scrollTop,
          viewport.clientHeight,
        ),
    )
  }, [])

  const updatePhysicalBottom = useCallback((settled = false) => {
    const state = {
      physicalBottom: readPhysicalBottom(),
      hasNewer: hasNewerRef.current,
    }
    if (settled) {
      controllerRef.current!.settlePhysical(state)
    } else {
      controllerRef.current!.observePhysical(state)
    }
    reportBottomState()
  }, [readPhysicalBottom, reportBottomState])

  useLayoutEffect(
    () =>
      subscribeBeforeChange((next, current) => {
        if (next.messageStyle === current.messageStyle) return
        const viewport = scrollRef.current
        if (!viewport || controllerRef.current?.wantsBottom) return
        const anchor = visibleLayoutAnchor(viewport)
        if (!anchor) return
        pendingLayoutAnchor.current = anchor
      }),
    [subscribeBeforeChange],
  )

  useEffect(() => {
    if (!retainInitialRange || rows.length === 0) return
    // `keepMounted` bridges only the prepared route's first browser paint.
    // Relinquish it on the following paint, after Virtua has a measured range;
    // this is a one-time ownership handoff, not scroll-position correction.
    let releaseFrame = 0
    const firstFrame = requestAnimationFrame(() => {
      releaseFrame = requestAnimationFrame(() => {
        setRetainInitialRange(false)
      })
    })
    return () => {
      cancelAnimationFrame(firstFrame)
      if (releaseFrame) cancelAnimationFrame(releaseFrame)
    }
  }, [retainInitialRange, rows.length])

  useLayoutEffect(() => {
    const anchor = pendingLayoutAnchor.current
    if (!anchor) return
    pendingLayoutAnchor.current = undefined
    const index = messagesRef.current.findIndex(
      (message) => String(message.messageId) === anchor.messageId,
    )
    if (index < 0) return
    // A render-mode change is one explicit layout revision. Ask Virtua once
    // to retain the captured product anchor; its own measurement scheduler
    // resolves the new row sizes without a product-side frame loop.
    listRef.current?.scrollToIndex(index, {
      align: "start",
      offset: -anchor.top,
    })
  }, [messageStyle])

  const positionBottom = useCallback(() => {
    const list = listRef.current
    const rowCount = rowCountRef.current
    if (!list || rowCount === 0) return
    controllerRef.current!.requestBottom()
    reportBottomState()
    // Row edge padding lives inside the measured first/last rows, so Virtua's
    // end alignment is the complete visual end. Its own scheduler owns any
    // measurement retries; the product issues exactly one request.
    list.scrollToIndex(rowCount - 1, { align: "end" })
  }, [reportBottomState])

  const positionInitial = useCallback((list: VirtualizerHandle) => {
    if (didPosition.current || rowCountRef.current === 0) return
    didPosition.current = true
    if (restoreTarget.mode === "bottom") {
      controllerRef.current!.requestBottom()
      reportBottomState()
      if (restoreTarget.scrollOffset != null) {
        list.scrollTo(restoreTarget.scrollOffset)
      } else {
        list.scrollToIndex(rowCountRef.current - 1, { align: "end" })
      }
    } else if (restoreTarget.mode === "exact") {
      list.scrollTo(restoreTarget.scrollOffset)
    } else {
      list.scrollToIndex(restoreTarget.index, {
        align: "start",
        offset: restoreTarget.offset,
      })
    }
  }, [reportBottomState, restoreTarget])

  const attachList = useCallback((list: VirtualizerHandle | null) => {
    // The handle is committed before Virtua has attached an external
    // `scrollRef`. Initial positioning is sequenced from the layout effect
    // below, after Virtua's own attachment microtask.
    listRef.current = list
  }, [])

  const saveScrollState = useCallback(() => {
    const list = listRef.current
    if (!list) return
    const ids = messagesRef.current.map((message) => message.id)
    messageListScrollStates.set(
      scrollStateKey,
      captureMessageListScrollState(
        list,
        ids,
        controllerRef.current!.logicalBottom,
        currentLayoutSignature(),
      ),
    )
  }, [currentLayoutSignature, scrollStateKey])

  useImperativeHandle(forwardedRef, () => ({
    scrollToBottom: positionBottom,
    scrollToMessage: (messageId) => {
      const index = messagesRef.current.findIndex(
        (message) => message.messageId === messageId,
      )
      if (index < 0) return false
      controllerRef.current!.browseHistory()
      reportBottomState()
      listRef.current?.scrollToIndex(index, { align: "center" })
      setHighlightedMessageId(messageId)
      if (highlightTimeout.current) clearTimeout(highlightTimeout.current)
      highlightTimeout.current = setTimeout(() => {
        setHighlightedMessageId(undefined)
      }, 2_000)
      return true
    },
  }), [positionBottom, reportBottomState])

  useLayoutEffect(() => {
    if (rows.length === 0) return
    const last = rows.at(-1)

    if (!didPosition.current) {
      previousMessageIds.current = itemIds
      let cancelled = false
      queueMicrotask(() => {
        if (cancelled || didPosition.current) return
        const list = listRef.current
        if (list) positionInitial(list)
      })
      return () => {
        cancelled = true
      }
    }

    if (slidingWindowAnchor) {
      const index = itemIds.indexOf(
        slidingWindowAnchor.id as ChatMessageRow["id"],
      )
      if (index >= 0) {
        listRef.current?.scrollToIndex(index, {
          align: "start",
          offset: slidingWindowAnchor.offset,
        })
      }
    }

    const followsOutgoingSend =
      last?.status === MessageSendingStatus.Sending &&
      dataChange !== "stable"
    if (shouldFollowMessageListChange({
      appended: dataChange === "append",
      outgoingSend: followsOutgoingSend,
      wantsBottom: controllerRef.current!.wantsBottom,
    })) {
      positionBottom()
    }
    previousMessageIds.current = itemIds
  }, [
    dataChange,
    itemIds,
    rows,
    slidingWindowAnchor,
    positionBottom,
    positionInitial,
  ])

  useLayoutEffect(() => {
    // Virtua can commit a short list whose complete contents fit the viewport
    // without producing another native scroll or resize notification. Check
    // readiness immediately and when Virtua commits its measured row DOM.
    // MutationObserver runs at the DOM handoff itself instead of polling
    // animation frames, and disconnects as soon as the list reports ready.
    const viewport = scrollRef.current
    if (!viewport) return
    const observer = typeof MutationObserver === "undefined"
      ? undefined
      : new MutationObserver(() => {
          if (reportFirstLayoutIfReady()) observer?.disconnect()
        })
    observer?.observe(viewport, { childList: true, subtree: true })
    if (reportFirstLayoutIfReady()) observer?.disconnect()
    return () => {
      observer?.disconnect()
    }
  }, [loading, reportFirstLayoutIfReady, rows.length])

  useLayoutEffect(() => {
    const viewport = scrollRef.current
    const content = contentRef.current
    if (!viewport || !content || typeof ResizeObserver === "undefined") {
      return
    }
    let queued = false
    let disposed = false
    const observer = new ResizeObserver(() => {
      if (queued) return
      queued = true
      const epoch = controllerRef.current!.epoch
      queueMicrotask(() => {
        queued = false
        if (disposed || !controllerRef.current!.isCurrent(epoch)) return
        if (
          controllerRef.current!.wantsBottom &&
          !hasNewerRef.current
        ) {
          // ResizeObserver runs after layout and before paint. Preserve the
          // measured end with one write for this viewport/content batch;
          // Virtua consumes the resulting native scroll event as its source
          // of truth. This is deliberately not an rAF settling loop.
          viewport.scrollTop = Math.max(
            0,
            viewport.scrollHeight - viewport.clientHeight,
          )
          updatePhysicalBottom()
        } else {
          updatePhysicalBottom()
        }
        reportFirstLayoutIfReady()
      })
    })
    observer.observe(viewport)
    observer.observe(content)
    return () => {
      disposed = true
      observer.disconnect()
    }
  }, [reportFirstLayoutIfReady, updatePhysicalBottom])

  useLayoutEffect(() => {
    const viewport = scrollRef.current
    if (!viewport) return
    const cancelBottomPositioning = () => {
      cancelPendingPositionOnScroll.current = true
      controllerRef.current!.browseHistory()
      reportBottomState()
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (
        event.key === "ArrowUp" ||
        event.key === "ArrowDown" ||
        event.key === "Home" ||
        event.key === "End"
      ) {
        const actions = visibleMessageActions(viewport)
        const target =
          event.target instanceof HTMLElement
            ? event.target.closest<HTMLElement>("[data-inline-message-action]")
            : null
        const currentIndex = target ? actions.indexOf(target) : -1
        const nextIndex = (() => {
          if (actions.length === 0) return -1
          if (event.key === "Home") return 0
          if (event.key === "End") return actions.length - 1
          if (event.key === "ArrowUp") {
            return currentIndex < 0
              ? actions.length - 1
              : Math.max(0, currentIndex - 1)
          }
          return currentIndex < 0
            ? 0
            : Math.min(actions.length - 1, currentIndex + 1)
        })()
        if (nextIndex >= 0) {
          event.preventDefault()
          cancelBottomPositioning()
          actions[nextIndex]!.focus({ preventScroll: true })
          return
        }
      }
      if (
        event.key === "ArrowUp" ||
        event.key === "PageUp" ||
        event.key === "Home"
      ) {
        cancelBottomPositioning()
      }
    }
    const onPointerDown = (event: PointerEvent) => {
      const scrollbarWidth = viewport.offsetWidth - viewport.clientWidth
      if (
        scrollbarWidth > 0 &&
        event.clientX >= viewport.getBoundingClientRect().right - scrollbarWidth
      ) {
        cancelBottomPositioning()
      }
    }
    viewport.addEventListener("wheel", cancelBottomPositioning, {
      passive: true,
    })
    viewport.addEventListener("touchstart", cancelBottomPositioning, {
      passive: true,
    })
    viewport.addEventListener("keydown", onKeyDown)
    viewport.addEventListener("pointerdown", onPointerDown)
    return () => {
      viewport.removeEventListener("wheel", cancelBottomPositioning)
      viewport.removeEventListener("touchstart", cancelBottomPositioning)
      viewport.removeEventListener("keydown", onKeyDown)
      viewport.removeEventListener("pointerdown", onPointerDown)
    }
  }, [reportBottomState])

  useLayoutEffect(
    () => () => {
      if (highlightTimeout.current) clearTimeout(highlightTimeout.current)
      saveScrollState()
      controllerRef.current!.browseHistory()
    },
    [saveScrollState],
  )

  useEffect(() => {
    const saveBeforeDocumentLeaves = () => saveScrollState()
    const saveWhenHidden = () => {
      if (document.visibilityState === "hidden") saveScrollState()
    }
    window.addEventListener("pagehide", saveBeforeDocumentLeaves)
    document.addEventListener("visibilitychange", saveWhenHidden)
    return () => {
      window.removeEventListener("pagehide", saveBeforeDocumentLeaves)
      document.removeEventListener("visibilitychange", saveWhenHidden)
    }
  }, [saveScrollState])

  const onScroll = useCallback(
    (offset: number) => {
      const list = listRef.current
      if (!list) return
      if (cancelPendingPositionOnScroll.current) {
        cancelPendingPositionOnScroll.current = false
        // A new imperative target cancels Virtua's still-measuring initial
        // bottom request and adopts the first user-produced native offset.
        list.scrollTo(offset)
      }
      updatePhysicalBottom()
      const firstIndex = list.findItemIndex(offset)
      const lastIndex = Math.min(
        rows.length - 1,
        list.findItemIndex(offset + list.viewportSize),
      )
      const first = rows.at(0)
      if (firstIndex < 8 && first && hasOlder && !loadingOlder) {
        onLoadOlder(messageWindowCursor(first))
      }
      const last = rows.at(-1)
      if (
        lastIndex >= rows.length - 8 &&
        last &&
        hasNewer &&
        !loadingNewer
      ) {
        onLoadNewer(messageWindowCursor(last))
      }
      const firstVisible = rows[firstIndex]
      const lastVisible = rows[lastIndex]
      if (
        firstVisible &&
        lastVisible &&
        BigInt(firstVisible.messageId) > 0n &&
        BigInt(lastVisible.messageId) > 0n
      ) {
        onVisibleRangeChange?.(
          firstVisible.messageId,
          lastVisible.messageId,
        )
      }
      reportFirstLayoutIfReady()
    },
    [
      hasNewer,
      hasOlder,
      loadingNewer,
      loadingOlder,
      onLoadNewer,
      onLoadOlder,
      onVisibleRangeChange,
      reportFirstLayoutIfReady,
      rows,
      updatePhysicalBottom,
    ],
  )

  return (
    <div
      ref={scrollRef}
      data-inline-message-list="viewport"
      data-inline-message-style={messageStyle}
      tabIndex={0}
      aria-label="Messages"
      {...stylex.props(styles.scroll)}
    >
      <div ref={contentRef} {...stylex.props(styles.content)}>
        <div aria-hidden="true" {...stylex.props(styles.topSpacer)} />
        <Virtualizer
          ref={attachList}
          scrollRef={scrollRef}
          data={rows}
          keepMounted={initialKeepMounted}
          bufferSize={640}
          itemSize={42}
          shift={shift}
          cache={initialCache}
          onScroll={onScroll}
          onScrollEnd={() => {
            updatePhysicalBottom(true)
            onScroll(listRef.current?.scrollOffset ?? 0)
            saveScrollState()
          }}
        >
          {(message, index) => (
            <MessageRow
              key={message.id}
              message={message}
              previous={rows[index - 1]}
              next={rows[index + 1]}
              showParticipants={showParticipants}
              highlighted={highlightedMessageId === message.messageId}
              firstInList={index === 0}
              lastInList={index === rows.length - 1}
              unreadBefore={
                unreadAfterMessageId != null &&
                compareInlineIds(
                  message.messageId,
                  unreadAfterMessageId,
                ) > 0 &&
                (rows[index - 1] == null ||
                  compareInlineIds(
                    rows[index - 1]!.messageId,
                    unreadAfterMessageId,
                  ) <= 0)
              }
              onOpenMessage={onOpenMessage}
              onOpenReplyThread={onOpenReplyThread}
              onResendMessage={onResendMessage}
              onReplyMessage={onReplyMessage}
              onTogglePinMessage={onTogglePinMessage}
              pinned={Boolean(
                pinnedMessageIds?.includes(String(message.messageId)),
              )}
              peer={peer}
              currentUserId={currentUserId}
              messageStyle={messageStyle}
            />
          )}
        </Virtualizer>
      </div>
      {loadingOlder ? <div {...stylex.props(styles.historyStatus)}>Loading earlier messages…</div> : null}
      {loadingNewer ? <div {...stylex.props(styles.newerHistoryStatus)}>Loading newer messages…</div> : null}
      {loading && rows.length === 0 ? (
        <div {...stylex.props(styles.loading)}>
          <InlineSpinner label="Loading messages" />
        </div>
      ) : null}
    </div>
  )
})

const styles = stylex.create({
  scroll: {
    position: "relative",
    minHeight: 0,
    height: "100%",
    overflowX: "hidden",
    overflowY: "auto",
    overscrollBehavior: "contain",
    overflowAnchor: "none",
    scrollbarGutter: "stable",
  },
  content: {
    minHeight: "100%",
    display: "flex",
    flexDirection: "column",
  },
  topSpacer: {
    flexGrow: 1,
    flexShrink: 1,
  },
  historyStatus: {
    position: "absolute",
    top: 4,
    left: 0,
    right: 0,
    zIndex: 1,
    paddingBlock: 6,
    color: colors.textTertiary,
    fontSize: 10,
    textAlign: "center",
  },
  newerHistoryStatus: {
    position: "absolute",
    bottom: 4,
    left: 0,
    right: 0,
    zIndex: 1,
    paddingBlock: 6,
    color: colors.textTertiary,
    fontSize: 10,
    textAlign: "center",
  },
  loading: {
    position: "absolute",
    inset: 0,
    display: "grid",
    placeItems: "center",
    color: colors.textTertiary,
    fontSize: 12,
    pointerEvents: "none",
  },
})
