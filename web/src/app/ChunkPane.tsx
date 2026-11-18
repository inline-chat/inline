/**
 * A pane whose body is its own chunk (Settings, Chat Info): the title strip,
 * then the chunk's body once it is there. The chunk loads when the pane
 * opens (or earlier, from the warm-up); until it arrives the pane is its
 * title strip over the window background (the same box, no spinner, nothing
 * moves when the body arrives). A failed load says so, with Try Again.
 *
 * The bodies' own code (models included) is in their chunks, not the shell's.
 */

import { useModel, useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { StripTitle, TitleStrip } from "./TitleStrip"
import type { Loadable } from "./views"

export function ChunkPane<C>(props: {
  readonly title: string
  readonly leading: ReactNode
  readonly chunk: Loadable<C>
  /** "Settings couldn't load", "Chat info couldn't load". */
  readonly failedText: string
  /** The body scrolls as a whole (chat info); otherwise the body manages its own scrolling (settings). */
  readonly scrolls?: boolean
  readonly children: (chunk: C) => ReactNode
}) {
  const { chunk } = props
  useModel(() => {
    void chunk.load()
    return {}
  }, [chunk])
  const loaded = useSignal(chunk.value)
  const failed = useSignal(chunk.error)
  return (
    <div {...stylex.props(styles.pane)}>
      <TitleStrip leading={props.leading}>
        <StripTitle>{props.title}</StripTitle>
      </TitleStrip>
      <div {...stylex.props(styles.body, props.scrolls && styles.scrolls)}>
        {loaded ? (
          props.children(loaded)
        ) : failed ? (
          <div role="alert" {...stylex.props(styles.failed)}>
            <p {...stylex.props(styles.text)}>{props.failedText} Check your connection and try again.</p>
            <Button variant="primary" onClick={() => void chunk.load()}>
              Try Again
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  )
}

const styles = stylex.create({
  pane: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minBlockSize: 0,
    backgroundColor: color.windowBackground,
  },
  body: {
    flexGrow: 1,
    minBlockSize: 0,
  },
  scrolls: {
    overflow: "auto",
  },
  failed: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: space.lg,
    blockSize: "100%",
    color: color.secondaryLabel,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  text: {
    margin: 0,
  },
})
