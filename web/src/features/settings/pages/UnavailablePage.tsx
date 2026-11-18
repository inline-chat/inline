/** A Mac settings page the web does not have yet, reached by a link such as `/settings/privacy`. */

import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import * as stylex from "@stylexjs/stylex"

export function UnavailablePage(props: { title: string }) {
  return (
    <p {...stylex.props(styles.text)}>
      {props.title} settings are not available on the web yet. They are in the Inline app for Mac and iOS.
    </p>
  )
}

const styles = stylex.create({
  text: { margin: 0, fontSize: font.sizeBody, color: color.secondaryLabel },
})
