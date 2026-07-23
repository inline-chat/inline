import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { colors, metrics } from "../styles/tokens.stylex"
import { SettingsAboutView } from "./SettingsAboutView"
import { SettingsAccountView } from "./SettingsAccountView"
import { SettingsAppearanceView } from "./SettingsAppearanceView"
import { SettingsDataStorageView } from "./SettingsDataStorageView"
import {
  SettingsSidebar,
  type SettingsCategory,
} from "./SettingsSidebar"

export function SettingsView() {
  const [category, setCategory] =
    useState<SettingsCategory>("account")

  return (
    <section {...stylex.props(styles.root)}>
      <header {...stylex.props(styles.toolbar)}>
        <h1 {...stylex.props(styles.title)}>Settings</h1>
      </header>
      <div {...stylex.props(styles.body)}>
        <SettingsSidebar value={category} onChange={setCategory} />
        <main {...stylex.props(styles.detail)}>
          {category === "account" ? <SettingsAccountView /> : null}
          {category === "appearance" ? <SettingsAppearanceView /> : null}
          {category === "storage" ? <SettingsDataStorageView /> : null}
          {category === "about" ? <SettingsAboutView /> : null}
        </main>
      </div>
    </section>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    backgroundColor: colors.content,
  },
  toolbar: {
    height: metrics.toolbarHeight,
    display: "flex",
    alignItems: "center",
    paddingInline: 16,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
    flexShrink: 0,
  },
  title: {
    margin: 0,
    fontSize: 14,
    fontWeight: 600,
  },
  body: {
    minHeight: 0,
    display: "grid",
    gridTemplateColumns: "180px minmax(0, 1fr)",
    flex: 1,
  },
  detail: {
    minWidth: 0,
    overflowY: "auto",
    borderLeftWidth: 1,
    borderLeftStyle: "solid",
    borderLeftColor: colors.separator,
  },
})
