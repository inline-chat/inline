/**
 * The settings region, as on the Mac: a searchable list of pages on the
 * leading side and the current page beside it, scrolling on its own. At a
 * narrow width it is one column with a back control. The page comes from the
 * `settings` destination (`props.page`) and choosing one calls
 * `props.onNavigate`, so the URL and Back go through the workspace. Every
 * control applies at once; there is no Save. See README.md.
 */

import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { Button, Listbox, TextField } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { useId } from "react"
import type { PermissionPrompt } from "../notifications"
import { createPermissionPrompt } from "../notifications/permission"
import { pageSpec, resolvePage, type SettingsPageId } from "./catalog"
import { BackIcon, PageIcon } from "./icons"
import { AboutPage } from "./pages/AboutPage"
import { AccountPage } from "./pages/AccountPage"
import { AppearancePage } from "./pages/AppearancePage"
import { DataPage } from "./pages/DataPage"
import { GeneralPage } from "./pages/GeneralPage"
import { NotificationsPage } from "./pages/NotificationsPage"
import { ShortcutsPage } from "./pages/ShortcutsPage"
import { UnavailablePage } from "./pages/UnavailablePage"
import type { SettingsSearchEntry } from "./search"
import { SettingsModel } from "./settings-model"
import type { SettingsViewProps } from "./types"

export function SettingsView(props: SettingsViewProps) {
  const hasAccount = props.account !== undefined
  const model = useModel(
    () =>
      new SettingsModel({
        page: props.page,
        hasAccount,
        onNavigate: props.onNavigate,
        platform: props.platform.info.shortcutModifier === "meta" ? "mac" : "other",
        ...(props.clock ? { clock: props.clock } : {}),
      }),
    [hasAccount, props.onNavigate],
  )
  const prompt = useModel(
    () => props.notificationPrompt ?? createPermissionPrompt({ notifications: props.platform.notifications }),
    [props.notificationPrompt, props.platform],
  )
  // Rendered from the prop, so the first frame after Back is already the right page.
  const resolved = resolvePage(props.page, model.pages)
  const title = resolved.kind === "page" ? pageSpec(resolved.id).title : resolved.title
  const narrowView = useSignal(model.narrowView)
  const searching = useSignal(model.searching)
  const titleId = useId()
  const rootRef = useElement(model.destination(props.page))
  const searchRef = useElement(model.searchField)
  const listFrameRef = useElement(model.pageListFrame)

  return (
    <div ref={rootRef} data-settings-view="" {...stylex.props(styles.root)}>
      <div {...stylex.props(styles.layout)}>
        <nav aria-label="Settings" {...stylex.props(styles.nav, narrowView === "page" && styles.hideWhenNarrow)}>
          <TextField
            ref={searchRef}
            label="Search settings"
            hideLabel
            type="search"
            placeholder="Search"
            autoComplete="off"
            spellCheck={false}
            onInput={(event) => model.setQuery(event.currentTarget.value)}
          />
          {searching ? (
            <SearchResults model={model} />
          ) : (
            <div ref={listFrameRef} {...stylex.props(styles.listFrame)}>
              <Listbox
                controller={model.pageList}
                style={styles.list}
                renderOption={(option) => (
                  <span {...stylex.props(styles.option)}>
                    <PageIcon icon={pageSpec(option.id as SettingsPageId).icon} />
                    <span {...stylex.props(styles.optionLabel)}>{option.label}</span>
                  </span>
                )}
              />
            </div>
          )}
        </nav>

        <section aria-labelledby={titleId} {...stylex.props(styles.content, narrowView === "list" && styles.hideWhenNarrow)}>
          <header {...stylex.props(styles.header)}>
            <Button
              variant="plain"
              size="small"
              icon={
                <span {...stylex.props(styles.backIcon)}>
                  <BackIcon />
                </span>
              }
              style={styles.back}
              onClick={() => model.showList()}
            >
              Settings
            </Button>
            <h1 id={titleId} {...stylex.props(styles.title)}>
              {title}
            </h1>
          </header>
          <div {...stylex.props(styles.scroll)}>
            <div {...stylex.props(styles.body)}>
              {resolved.kind === "page" ? (
                <PageContent model={model} page={resolved.id} view={props} prompt={prompt} />
              ) : (
                <UnavailablePage title={resolved.title} />
              )}
            </div>
          </div>
        </section>
      </div>
    </div>
  )
}

function PageContent(props: { model: SettingsModel; page: SettingsPageId; view: SettingsViewProps; prompt: PermissionPrompt }) {
  const { model, view } = props
  switch (props.page) {
    case "account":
      return view.account ? <AccountPage model={model} account={view.account} pendingCount={view.pendingCount ?? 0} /> : null
    case "general":
      return <GeneralPage model={model} preferences={view.preferences} platform={view.platform} />
    case "appearance":
      return <AppearancePage model={model} appearance={view.appearance} />
    case "notifications":
      return <NotificationsPage model={model} preferences={view.preferences} platform={view.platform} prompt={props.prompt} />
    case "data":
      return <DataPage model={model} platform={view.platform} {...(view.onClearCachedMedia ? { onClearCachedMedia: view.onClearCachedMedia } : {})} />
    case "hotkeys":
      return <ShortcutsPage model={model} shortcuts={view.shortcuts} />
    case "updates":
      return <AboutPage model={model} platform={view.platform} buildId={view.buildId} />
  }
}

function SearchResults(props: { model: SettingsModel }) {
  const results = useSignal(props.model.results)
  const ref = useElement(props.model.resultList.passiveRoot)
  return (
    <div {...stylex.props(styles.listFrame)}>
      <div ref={ref} {...stylex.props(styles.results)}>
        {results.map((result) => (
          <ResultRow key={result.id} model={props.model} result={result} />
        ))}
      </div>
      <p role="status" {...stylex.props(results.length === 0 ? styles.empty : styles.visuallyHidden)}>
        {results.length === 0 ? "No settings match." : results.length === 1 ? "1 setting" : `${results.length} settings`}
      </p>
    </div>
  )
}

function ResultRow(props: { model: SettingsModel; result: SettingsSearchEntry }) {
  const { resultList } = props.model
  const ref = useElement(resultList.option(props.result.id))
  const active = useSignal(resultList.isActive(props.result.id))
  return (
    <div ref={ref} {...stylex.props(styles.result, active && styles.resultActive)}>
      <span {...stylex.props(styles.resultTitle)}>{props.result.title}</span>
      <span {...stylex.props(styles.resultContext, active && styles.resultContextActive)}>
        {props.result.pageTitle} · {props.result.section}
      </span>
    </div>
  )
}

/** Below 600px of the settings pane (its own width, not the window's), one column with a back control. */
const NARROW = "@container (max-width: 599px)"

const styles = stylex.create({
  root: {
    containerType: "inline-size",
    blockSize: "100%",
    inlineSize: "100%",
    minBlockSize: 0,
    overflow: "hidden",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  layout: {
    display: "grid",
    gridTemplateColumns: { default: "220px minmax(0, 1fr)", [NARROW]: "minmax(0, 1fr)" },
    blockSize: "100%",
    minBlockSize: 0,
  },
  nav: {
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    minBlockSize: 0,
    paddingBlock: space.lg,
    paddingInline: space.md,
    backgroundColor: color.sidebarBackground,
    borderInlineEndWidth: { default: "1px", [NARROW]: "0" },
    borderInlineEndStyle: "solid",
    borderInlineEndColor: color.separator,
  },
  hideWhenNarrow: { display: { default: "flex", [NARROW]: "none" } },
  listFrame: { display: "flex", flexDirection: "column", flexGrow: 1, minBlockSize: 0, overflowY: "auto" },
  list: { borderStyle: "none", backgroundColor: "transparent", padding: 0 },
  option: { display: "inline-flex", alignItems: "center", gap: space.md, minInlineSize: 0, color: "inherit" },
  optionLabel: { overflow: "hidden", textOverflow: "ellipsis" },
  results: { display: "flex", flexDirection: "column", gap: space.xxs, outline: "none" },
  result: {
    display: "flex",
    flexDirection: "column",
    gap: space.xxs,
    paddingBlock: space.sm,
    paddingInline: space.md,
    borderRadius: radius.menuItem,
    cursor: "default",
  },
  resultActive: { backgroundColor: color.selectedContentBackground, color: color.selectedText },
  resultTitle: { fontSize: font.sizeBody },
  resultContext: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  resultContextActive: { color: "inherit", opacity: 0.85 },
  empty: { margin: 0, paddingInline: space.md, fontSize: font.sizeCallout, color: color.secondaryLabel },
  visuallyHidden: {
    position: "absolute",
    inlineSize: "1px",
    blockSize: "1px",
    margin: "-1px",
    padding: 0,
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
  content: { display: "flex", flexDirection: "column", minBlockSize: 0, minInlineSize: 0 },
  header: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    paddingBlock: space.lg,
    paddingInline: space.xxl,
    borderBlockEndWidth: "1px",
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
  },
  back: { display: { default: "none", [NARROW]: "inline-flex" } },
  // The chevron points back in either direction.
  backIcon: { display: "inline-flex", transform: { default: null, ":dir(rtl)": "scaleX(-1)" } },
  title: { margin: 0, fontSize: font.sizeTitle2, fontWeight: font.weightSemibold },
  scroll: { flexGrow: 1, minBlockSize: 0, overflowY: "auto", overscrollBehavior: "contain" },
  body: {
    boxSizing: "border-box",
    display: "flex",
    flexDirection: "column",
    gap: space.xxl,
    inlineSize: "100%",
    maxInlineSize: "720px",
    marginInline: "auto",
    paddingBlock: space.xl,
    paddingInline: { default: space.xxl, [NARROW]: space.lg },
    paddingBlockEnd: space.huge,
  },
})
