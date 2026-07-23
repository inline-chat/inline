import { InlineCoreRendererRegistry } from "./InlineCoreRendererRegistry"
import { createInlineBroadcastCoreRendererClient } from "./createInlineBroadcastCoreRendererClient"

/** Renderer registry for the BroadcastChannel + Web-Lock compatibility path. */
export class InlineBroadcastCoreRegistry extends InlineCoreRendererRegistry {
  constructor() {
    super(createInlineBroadcastCoreRendererClient)
  }
}
