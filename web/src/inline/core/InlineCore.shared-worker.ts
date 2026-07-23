import {
  InlineCoreHost,
  type InlineCoreMessagePort,
} from "./InlineCoreHost"
import {
  createInlineCoreAccountOwnershipAcquirer,
  type InlineCoreLockManager,
} from "./InlineCoreAccountOwnership"

type SharedWorkerConnectEvent = Event & {
  ports: MessagePort[]
}

type InlineSharedWorkerScope = {
  addEventListener(
    type: "connect",
    listener: (event: SharedWorkerConnectEvent) => void,
  ): void
}

const scope = self as unknown as InlineSharedWorkerScope
const locks = (
  self as unknown as {
    navigator: { locks?: InlineCoreLockManager }
  }
).navigator.locks
const host = new InlineCoreHost({
  acquireAccountOwnership:
    createInlineCoreAccountOwnershipAcquirer(locks),
})

scope.addEventListener("connect", (event) => {
  for (const port of event.ports) {
    host.attachPort(
      port as unknown as InlineCoreMessagePort,
    )
  }
})
