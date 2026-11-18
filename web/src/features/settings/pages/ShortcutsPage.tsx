/** Keyboard Shortcuts: the command registry's reference for this platform, grouped by category, with a filter. */

import { Kbd, TextField } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { ShortcutReference } from "@inline/view"
import * as stylex from "@stylexjs/stylex"
import { Fragment, useState } from "react"
import { filterShortcuts, keyCaps, spokenCombo } from "../format"
import { Note, Row, Section } from "../Rows"
import type { SettingsModel } from "../settings-model"

export function ShortcutsPage(props: { model: SettingsModel; shortcuts: ShortcutReference }) {
  // View-only filter text: not restored, not shared.
  const [filter, setFilter] = useState("")
  const os = props.shortcuts.platform.os
  const categories = filterShortcuts(props.shortcuts, filter)
  return (
    <>
      <Section title="Shortcuts" description={`Shortcuts for ${props.shortcuts.label}.`}>
        <Row
          model={props.model}
          item="shortcuts"
          stacked
          control={({ titleId }) => (
            <TextField
              label="Filter shortcuts"
              hideLabel
              type="search"
              placeholder="Filter by name or key"
              aria-describedby={titleId}
              autoComplete="off"
              spellCheck={false}
              defaultValue={filter}
              onInput={(event) => setFilter(event.currentTarget.value)}
              style={styles.filter}
            />
          )}
        />
      </Section>

      {categories.length === 0 ? <Note live>No shortcuts match.</Note> : null}

      {categories.map((category) => (
        <section key={category.category} aria-label={category.title} {...stylex.props(styles.category)}>
          <h2 {...stylex.props(styles.categoryTitle)}>{category.title}</h2>
          <dl {...stylex.props(styles.list)}>
            {category.commands.map((command) => (
              <div key={command.id} {...stylex.props(styles.command)}>
                <dt {...stylex.props(styles.commandTitle)}>{command.title}</dt>
                <dd {...stylex.props(styles.keys)}>
                  {command.keys.map((key, index) => (
                    <Fragment key={key.combo}>
                      {index > 0 ? <span {...stylex.props(styles.or)}>or</span> : null}
                      <Kbd keys={keyCaps(key.display, os)} label={spokenCombo(key.display, os)} />
                    </Fragment>
                  ))}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      ))}
    </>
  )
}

const styles = stylex.create({
  filter: { inlineSize: "100%" },
  category: { display: "flex", flexDirection: "column", gap: space.sm },
  categoryTitle: {
    margin: 0,
    paddingInline: space.md,
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
  },
  list: {
    margin: 0,
    display: "flex",
    flexDirection: "column",
    borderRadius: radius.content,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    overflow: "hidden",
  },
  command: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: space.lg,
    paddingBlock: space.sm,
    paddingInline: space.lg,
    borderBlockStartWidth: { default: "1px", ":first-child": "0" },
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  commandTitle: { fontSize: font.sizeBody, color: color.label, minInlineSize: 0 },
  keys: { margin: 0, display: "flex", alignItems: "center", gap: space.sm, flexShrink: 0 },
  or: { fontSize: font.sizeCallout, color: color.secondaryLabel },
})
