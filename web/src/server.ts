import {
  createStartHandler,
  defaultStreamHandler,
} from "@tanstack/react-start/server"
import { createServerEntry } from "@tanstack/react-start/server-entry"
import { withInlineWebSecurityHeaders } from "./platform/security/InlineWebSecurityHeaders"

const startHandler = createStartHandler(defaultStreamHandler)

export default createServerEntry({
  async fetch(...args) {
    const response = await startHandler(...args)
    return withInlineWebSecurityHeaders(response, {
      production: import.meta.env.PROD,
    })
  },
})
