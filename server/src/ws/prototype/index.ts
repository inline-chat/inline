import Elysia, { t } from "elysia"

// basic protocol
export const Response = t.Object({
  message: t.String(),
})

export const wsPrototype = new Elysia().ws("/prototype", {
  response: t.Object({
    message: t.String(),
  }),

  open(ws) {
    ws.send({ message: "string" })
    console.log("open")
  },
  close(ws) {
    console.log("close")
  },
  perMessageDeflate: {
    compress: "32KB",
    decompress: "32KB",
  },
  sendPings: true,

  message(ws, message) {
    console.log({ message })
  },
})
