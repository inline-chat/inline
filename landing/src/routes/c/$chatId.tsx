import { createFileRoute } from "@tanstack/react-router"

import { chatShortcutResponse } from "~/lib/chatShortcut"

export const Route = createFileRoute("/c/$chatId")({
  server: {
    handlers: {
      GET: ({ params }) => chatShortcutResponse(params.chatId),
      HEAD: ({ params }) => chatShortcutResponse(params.chatId, false),
    },
  },
})
