/**
 * UI lab: every primitive of @inline/ui in every state, in light, dark or
 * system appearance and in either writing direction. It is the review
 * surface for the kit and the source of its visual test screenshots.
 *
 * Query parameters set the starting state for screenshots:
 *   lab-ui.html?theme=dark&dir=rtl
 */

import * as stylex from "@stylexjs/stylex"
import { StrictMode, useState } from "react"
import { createRoot } from "react-dom/client"
import { color } from "../../../packages/ui/src/tokens/color.stylex"
import { font } from "../../../packages/ui/src/tokens/font.stylex"
import { radius } from "../../../packages/ui/src/tokens/radius.stylex"
import { space } from "../../../packages/ui/src/tokens/space.stylex"
import {
  ButtonsSection,
  CollectionsSection,
  ControlsSection,
  DisplaySection,
  FieldsSection,
  MenusSection,
  OverlaysSection,
  SplitSection,
  TokensSection,
  ToastSection,
} from "./sections"

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

type Theme = "system" | "light" | "dark"
type Dir = "ltr" | "rtl"

const params = new URLSearchParams(location.search)
const initialTheme: Theme = params.get("theme") === "dark" ? "dark" : params.get("theme") === "light" ? "light" : "system"
const initialDir: Dir = params.get("dir") === "rtl" ? "rtl" : "ltr"

/** Apply the appearance and direction to the document (from event handlers and at start; no effects). */
const applyTheme = (theme: Theme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}
const applyDir = (dir: Dir) => {
  document.documentElement.dir = dir
}
applyTheme(initialTheme)
applyDir(initialDir)

const sections = [
  { id: "tokens", title: "Tokens", Component: TokensSection },
  { id: "buttons", title: "Button and IconButton", Component: ButtonsSection },
  { id: "fields", title: "TextField", Component: FieldsSection },
  { id: "display", title: "Kbd, Badge, Avatar, Progress, ScrollArea", Component: DisplaySection },
  { id: "menus", title: "Menu and ContextMenu", Component: MenusSection },
  { id: "overlays", title: "Popover, Tooltip, Dialog and Sheet", Component: OverlaysSection },
  { id: "collections", title: "Listbox, Combobox and Tabs", Component: CollectionsSection },
  { id: "controls", title: "Toggle and Switch", Component: ControlsSection },
  { id: "split", title: "SplitView", Component: SplitSection },
  { id: "toast", title: "Toast", Component: ToastSection },
]

function Lab() {
  const [theme, setTheme] = useState<Theme>(initialTheme)
  const [dir, setDir] = useState<Dir>(initialDir)
  return (
    <div {...stylex.props(styles.page)}>
      <header {...stylex.props(styles.header)}>
        <h1 {...stylex.props(styles.title)}>UI lab</h1>
        <Segmented
          label="Appearance"
          value={theme}
          options={["system", "light", "dark"]}
          onChange={(next) => {
            applyTheme(next)
            setTheme(next)
          }}
        />
        <Segmented
          label="Direction"
          value={dir}
          options={["ltr", "rtl"]}
          onChange={(next) => {
            applyDir(next)
            setDir(next)
          }}
        />
        <nav aria-label="Sections" {...stylex.props(styles.nav)}>
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} {...stylex.props(styles.navLink)}>
              {section.title}
            </a>
          ))}
        </nav>
      </header>
      <main {...stylex.props(styles.main)}>
        {sections.map(({ id, title, Component }) => (
          <section key={id} id={id} aria-labelledby={`${id}-title`} {...stylex.props(styles.section)}>
            <h2 id={`${id}-title`} {...stylex.props(styles.sectionTitle)}>
              {title}
            </h2>
            <Component />
          </section>
        ))}
      </main>
    </div>
  )
}

/** The lab's own switcher: plain radio buttons, so it does not depend on the kit it tests. */
function Segmented<T extends string>(props: { label: string; value: T; options: readonly T[]; onChange: (value: T) => void }) {
  return (
    <fieldset {...stylex.props(styles.segmented)}>
      <legend {...stylex.props(styles.legend)}>{props.label}</legend>
      {props.options.map((option) => (
        <label key={option} {...stylex.props(styles.segment)}>
          <input
            type="radio"
            name={props.label}
            value={option}
            checked={props.value === option}
            onChange={() => props.onChange(option)}
          />
          {option}
        </label>
      ))}
    </fieldset>
  )
}

const styles = stylex.create({
  page: {
    position: "fixed",
    inset: 0,
    overflow: "auto",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: {
    position: "sticky",
    top: 0,
    zIndex: 1,
    display: "flex",
    flexWrap: "wrap",
    alignItems: "center",
    gap: space.xl,
    paddingBlock: space.md,
    paddingInline: space.xl,
    backgroundColor: color.sidebarBackground,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  title: { margin: 0, fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  nav: { display: "flex", flexWrap: "wrap", gap: space.md },
  navLink: { color: color.link, fontSize: font.sizeCallout, textDecoration: "none" },
  main: {
    display: "flex",
    flexDirection: "column",
    gap: space.huge,
    maxWidth: "1040px",
    paddingBlock: space.xxxl,
    paddingInline: space.xl,
    marginInline: "auto",
  },
  section: {
    display: "flex",
    flexDirection: "column",
    gap: space.lg,
    scrollMarginTop: "80px",
  },
  sectionTitle: {
    margin: 0,
    paddingBlockEnd: space.sm,
    fontSize: font.sizeTitle2,
    fontWeight: font.weightSemibold,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  segmented: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.md,
    margin: 0,
    paddingBlock: space.xxs,
    paddingInline: space.md,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    borderRadius: radius.control,
  },
  legend: { float: "inline-start", marginInlineEnd: space.md, color: color.secondaryLabel },
  segment: { display: "inline-flex", alignItems: "center", gap: space.xxs },
})

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root")

createRoot(root).render(
  <StrictMode>
    <Lab />
  </StrictMode>,
)
