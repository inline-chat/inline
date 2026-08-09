import { Outlet } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useLayoutEffect, useRef } from "react"
import { colors } from "../styles/tokens.stylex"
import { useAppRoutePresentation } from "./AppRoutePresentation"

/**
 * TanStack owns route preparation and commit timing. This cover has one
 * narrower job: prevent the previously resolved detail from appearing under
 * a new chat URL while React commits the next match.
 */
export function AppRouteOutlet() {
  const { targetPath } = useAppRoutePresentation()
  const content = useRef<HTMLDivElement>(null)
  const presentation = useRef<HTMLDivElement>(null)
  const wasPresenting = useRef(false)

  useLayoutEffect(() => {
    if (targetPath) {
      presentation.current?.focus({ preventScroll: true })
    } else if (wasPresenting.current) {
      content.current?.focus({ preventScroll: true })
    }
    wasPresenting.current = targetPath != null
  }, [targetPath])

  return (
    <>
      <div
        ref={content}
        data-inline-route-content
        tabIndex={-1}
        inert={targetPath ? true : undefined}
        aria-hidden={targetPath ? true : undefined}
        {...stylex.props(styles.content)}
      >
        <Outlet />
      </div>
      {targetPath ? (
        <div
          ref={presentation}
          role="status"
          aria-label="Loading conversation…"
          aria-live="polite"
          aria-atomic="true"
          tabIndex={-1}
          data-inline-route-presentation={targetPath}
          {...stylex.props(styles.presentation)}
        >
          <span aria-hidden="true" {...stylex.props(styles.spinner)} />
        </div>
      ) : null}
    </>
  )
}

const styles = stylex.create({
  content: {
    width: "100%",
    height: "100%",
    minWidth: 0,
    minHeight: 0,
    outline: "none",
  },
  presentation: {
    position: "absolute",
    zIndex: 20,
    inset: 0,
    display: "grid",
    placeItems: "center",
    backgroundColor: colors.content,
    color: colors.textSecondary,
    fontSize: 12,
    outline: "none",
  },
  spinner: {
    width: 14,
    height: 14,
    borderWidth: 2,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderTopColor: colors.textSecondary,
    borderRadius: "50%",
    animationName: stylex.keyframes({
      to: { transform: "rotate(360deg)" },
    }),
    animationDuration: "0.8s",
    animationTimingFunction: "linear",
    animationIterationCount: "infinite",
  },
})
