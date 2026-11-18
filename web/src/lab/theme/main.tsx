/**
 * Theme lab: every theme in light and dark with the kit's main surfaces, the
 * appearance, density and type controls bound to the document (persisted, so
 * a reload shows the pre-paint boot path), and the contrast table.
 *
 * Query parameters set the document's starting state for screenshots:
 *   lab-theme.html?appearance=dark&theme=pink&textSize=16
 */

import * as stylex from "@stylexjs/stylex"
import { type ReactNode, StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { THEME_IDS, THEME_TITLES, type ThemeId, type Variant, contrastRows, type ContrastRow } from "@inline/ui/theme"
import {
  AppearanceSwitch,
  Button,
  LineSpacingControl,
  MessageFontControl,
  SidebarItemSizeControl,
  TextField,
  TextSizeStepper,
  ThemeScope,
  ThemeSwatchGrid,
} from "@inline/ui/react"
import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { chatText } from "@inline/ui/tokens/chat-text.stylex"
import { color } from "@inline/ui/tokens/color.stylex"
import { density } from "@inline/ui/tokens/density.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { themeColor } from "@inline/ui/tokens/theme-color.stylex"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

// First thing: apply the stored appearance to <html> in this task, before React renders.
const appearance = startDocumentAppearance()
applyQuery(appearance)

const rows = contrastRows()

function Lab() {
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>Theme lab</h1>
        <p {...stylex.props(styles.note)}>
          Controls apply to this document and persist; reload to check there is no flash of the wrong appearance.
        </p>
      </header>
      <main {...stylex.props(styles.main)}>
        <section aria-labelledby="controls-title" {...stylex.props(styles.section)}>
          <h2 id="controls-title" {...stylex.props(styles.sectionTitle)}>
            Appearance settings
          </h2>
          <div {...stylex.props(styles.controls)}>
            <Row label="Appearance">
              <AppearanceSwitch controller={appearance} />
            </Row>
            <Row label="Message text size">
              <TextSizeStepper controller={appearance} />
            </Row>
            <Row label="Line spacing">
              <LineSpacingControl controller={appearance} />
            </Row>
            <Row label="Message font">
              <MessageFontControl controller={appearance} />
            </Row>
            <Row label="Sidebar item size">
              <SidebarItemSizeControl controller={appearance} />
            </Row>
          </div>
          <ThemeSwatchGrid controller={appearance} />
        </section>

        <section aria-labelledby="themes-title" {...stylex.props(styles.section)}>
          <h2 id="themes-title" {...stylex.props(styles.sectionTitle)}>
            Every theme, light and dark
          </h2>
          <div {...stylex.props(styles.grid)}>
            {THEME_IDS.map((theme) =>
              (["light", "dark"] as const).map((variant) => <Specimen key={`${theme}-${variant}`} theme={theme} variant={variant} />),
            )}
          </div>
        </section>

        <section aria-labelledby="contrast-title" {...stylex.props(styles.section)}>
          <h2 id="contrast-title" {...stylex.props(styles.sectionTitle)}>
            Contrast (WCAG 2, AA)
          </h2>
          <ContrastTable rows={rows} />
        </section>
      </main>
    </div>
  )
}

function Row(props: { label: string; children: ReactNode }) {
  return (
    <div {...stylex.props(styles.row)}>
      <span {...stylex.props(styles.rowLabel)}>{props.label}</span>
      {props.children}
    </div>
  )
}

/** One theme in one appearance: window, sidebar, message run, controls, a menu, a field, focus rings. */
function Specimen(props: { theme: ThemeId; variant: Variant }) {
  return (
    <figure {...stylex.props(styles.figure)}>
      <figcaption {...stylex.props(styles.caption)}>
        {THEME_TITLES[props.theme]}, {props.variant}
      </figcaption>
      <ThemeScope theme={props.theme} appearance={props.variant} style={styles.window}>
        <div {...stylex.props(styles.sidebar)}>
          <div {...stylex.props(styles.sidebarRow, styles.sidebarRowSelected)}>
            <span {...stylex.props(styles.sidebarIcon, styles.sidebarIconSelected)} />
            General
          </div>
          <div {...stylex.props(styles.sidebarRow)}>
            <span {...stylex.props(styles.sidebarIcon)} />
            Design
          </div>
          <div {...stylex.props(styles.sidebarRow)}>
            <span {...stylex.props(styles.sidebarIcon)} />
            Mo
          </div>
          <div {...stylex.props(styles.sidebarFolder)}>Folder</div>
        </div>
        <div {...stylex.props(styles.content)}>
          <div {...stylex.props(styles.toolbar)}>
            <span {...stylex.props(styles.toolbarTitle)}>General</span>
            <span {...stylex.props(styles.secondary)}>3 members</span>
          </div>
          <div {...stylex.props(styles.messages)}>
            <div {...stylex.props(styles.bubble, styles.otherBubble)}>
              Shipping the theme lab today, see{" "}
              <span {...stylex.props(styles.bubbleLink)}>inline.chat/docs</span>
            </div>
            <div {...stylex.props(styles.bubble, styles.otherBubble)}>Light and dark both?</div>
            <div {...stylex.props(styles.bubble, styles.ownBubble)}>Yes, and every Mac theme.</div>
            <div {...stylex.props(styles.emoji)} aria-label="emoji-only message">
              🎉
            </div>
          </div>
          <div {...stylex.props(styles.controlsRow)}>
            <Button variant="primary" size="small">
              Send
            </Button>
            <Button size="small">Cancel</Button>
            <span {...stylex.props(styles.focusSample)}>Focus ring</span>
          </div>
          <div {...stylex.props(styles.controlsRow)}>
            <TextField label="Message" hideLabel placeholder="Message" size="small" />
          </div>
          <div role="presentation" {...stylex.props(styles.menu)}>
            <div {...stylex.props(styles.menuItem)}>Reply</div>
            <div {...stylex.props(styles.menuItem, styles.menuItemSelected)}>Copy Text</div>
            <div {...stylex.props(styles.menuItem, styles.destructive)}>Delete</div>
          </div>
          <div {...stylex.props(styles.replyPane)}>Reply thread pane</div>
        </div>
      </ThemeScope>
    </figure>
  )
}

function ContrastTable(props: { rows: readonly ContrastRow[] }) {
  return (
    <div {...stylex.props(styles.tableWrap)}>
      <table {...stylex.props(styles.table)}>
        <thead>
          <tr>
            <th {...stylex.props(styles.th)}>Theme</th>
            <th {...stylex.props(styles.th)}>Pair</th>
            <th {...stylex.props(styles.th)}>Colors</th>
            <th {...stylex.props(styles.th)}>Ratio</th>
            <th {...stylex.props(styles.th)}>Minimum</th>
            <th {...stylex.props(styles.th)}>Result</th>
          </tr>
        </thead>
        <tbody>
          {props.rows.map((row) => (
            <tr key={`${row.theme}-${row.variant}-${row.pair.id}`}>
              <td {...stylex.props(styles.td)}>
                {THEME_TITLES[row.theme]} {row.variant}
              </td>
              <td {...stylex.props(styles.td)}>{row.pair.title}</td>
              <td {...stylex.props(styles.td, styles.mono)}>
                {row.foreground} on {row.background}
              </td>
              <td {...stylex.props(styles.td, styles.mono)}>{row.ratio.toFixed(2)}</td>
              <td {...stylex.props(styles.td, styles.mono)}>{row.pair.minimum}</td>
              <td {...stylex.props(styles.td, row.passes ? styles.pass : styles.fail)}>{row.passes ? "Pass" : "Fail"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/** `?appearance=dark&theme=pink&textSize=16` for screenshots. */
function applyQuery(controller: typeof appearance) {
  const params = new URLSearchParams(location.search)
  const patch: Record<string, unknown> = {}
  for (const key of ["appearance", "theme", "messageFont", "sidebarItemSize"]) {
    const value = params.get(key)
    if (value) patch[key] = value
  }
  for (const key of ["textSize", "lineSpacing"]) {
    const value = params.get(key)
    if (value) patch[key] = Number(value)
  }
  if (Object.keys(patch).length > 0) controller.update(patch)
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    overflow: "auto",
    color: color.label,
    backgroundColor: color.windowBackground,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: {
    display: "flex",
    flexWrap: "wrap",
    alignItems: "baseline",
    gap: space.lg,
    paddingBlock: space.md,
    paddingInline: space.xl,
    backgroundColor: color.sidebarBackground,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  note: { margin: 0, color: color.secondaryLabel, fontSize: font.sizeCallout },
  main: {
    display: "flex",
    flexDirection: "column",
    gap: space.huge,
    maxWidth: "1200px",
    paddingBlock: space.xxxl,
    paddingInline: space.xl,
    marginInline: "auto",
  },
  section: { display: "flex", flexDirection: "column", gap: space.lg },
  sectionTitle: {
    margin: 0,
    paddingBlockEnd: space.sm,
    fontSize: font.sizeTitle2,
    fontWeight: font.weightSemibold,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  controls: { display: "flex", flexDirection: "column", gap: space.md },
  row: { display: "flex", flexWrap: "wrap", alignItems: "center", gap: space.lg },
  rowLabel: { minWidth: "160px", color: color.secondaryLabel },
  grid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fill, minmax(min(100%, 520px), 1fr))",
    gap: space.xl,
  },
  figure: { margin: 0, display: "flex", flexDirection: "column", gap: space.xs },
  caption: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  window: {
    display: "flex",
    minHeight: "340px",
    overflow: "hidden",
    borderRadius: radius.content,
    boxShadow: shadow.popover,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  sidebar: {
    display: "flex",
    flexDirection: "column",
    gap: "1px",
    width: "150px",
    flexShrink: 0,
    padding: space.sm,
    backgroundColor: color.sidebarBackground,
    borderInlineEndWidth: "1px",
    borderInlineEndStyle: "solid",
    borderInlineEndColor: color.separator,
  },
  sidebarRow: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    height: density.sidebarRowHeight,
    paddingInline: space.sm,
    borderRadius: radius.sidebarItem,
    color: color.label,
  },
  sidebarRowSelected: { backgroundColor: color.unemphasizedSelectedContentBackground },
  sidebarIcon: {
    width: density.sidebarRowIconSize,
    height: density.sidebarRowIconSize,
    flexShrink: 0,
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
  },
  sidebarIconSelected: { backgroundColor: color.accent },
  sidebarFolder: {
    display: "flex",
    alignItems: "center",
    height: density.sidebarFolderRowHeight,
    paddingInline: space.sm,
    color: color.secondaryLabel,
  },
  content: { display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0, gap: space.md },
  toolbar: {
    display: "flex",
    alignItems: "baseline",
    gap: space.md,
    height: size.toolbar,
    boxSizing: "border-box",
    paddingBlockStart: space.lg,
    paddingInline: space.lg,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  toolbarTitle: { fontWeight: font.weightSemibold },
  secondary: { color: color.secondaryLabel, fontSize: font.sizeCallout },
  messages: {
    display: "flex",
    flexDirection: "column",
    gap: "2px",
    paddingInline: space.lg,
    fontFamily: chatText.messageFontFamily,
    fontSize: chatText.messageFontSize,
    lineHeight: chatText.messageLineHeight,
  },
  bubble: {
    maxWidth: "75%",
    paddingBlock: "6px",
    paddingInline: "11px",
    borderRadius: radius.bubble,
    overflowWrap: "anywhere",
  },
  otherBubble: { alignSelf: "flex-start", backgroundColor: color.secondaryBubble, color: color.secondaryBubbleText },
  ownBubble: { alignSelf: "flex-end", backgroundColor: color.bubble, color: color.onAccent },
  bubbleLink: { color: themeColor.secondaryBubbleLink, textDecoration: "underline" },
  emoji: { alignSelf: "flex-end", fontSize: chatText.emojiLarge, lineHeight: 1.1 },
  controlsRow: { display: "flex", alignItems: "center", gap: space.md, paddingInline: space.lg },
  focusSample: {
    paddingBlock: space.xxs,
    paddingInline: space.sm,
    borderRadius: radius.control,
    fontSize: font.sizeCallout,
    outline: `${size.focusRingWidth} solid ${color.focusRing}`,
  },
  menu: {
    alignSelf: "flex-start",
    marginInline: space.lg,
    minWidth: "160px",
    padding: "5px",
    backgroundColor: color.menuBackground,
    borderRadius: radius.menu,
    boxShadow: shadow.menu,
  },
  menuItem: {
    display: "flex",
    alignItems: "center",
    height: size.menuItem,
    paddingInline: space.md,
    borderRadius: radius.menuItem,
  },
  menuItemSelected: { backgroundColor: color.selectedMenuItem, color: color.selectedMenuItemText },
  destructive: { color: color.destructive },
  replyPane: {
    marginBlockStart: "auto",
    paddingBlock: space.md,
    paddingInline: space.lg,
    backgroundColor: themeColor.replyPaneBackground,
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  tableWrap: { overflowX: "auto" },
  table: { borderCollapse: "collapse", width: "100%", fontSize: font.sizeCallout },
  th: {
    textAlign: "start",
    paddingBlock: space.xs,
    paddingInline: space.sm,
    color: color.secondaryLabel,
    fontWeight: font.weightMedium,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  td: {
    paddingBlock: space.xs,
    paddingInline: space.sm,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  mono: { fontFamily: font.familyMono, fontVariantNumeric: "tabular-nums" },
  pass: { color: color.green },
  fail: { color: color.red, fontWeight: font.weightSemibold },
})

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root")

createRoot(root).render(
  <StrictMode>
    <Lab />
  </StrictMode>,
)
