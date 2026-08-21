import type {
  AuthBeginRequest,
  AuthBeginResult,
  AuthBeginBrowserRequest,
  AuthBeginBrowserResult,
  AuthBrowserStatusRequest,
  AuthBrowserStatusResult,
  AuthCompleteRequest,
  AuthCompleteResult,
} from "@inline-chat/protocol/core"
import type {
  InlineProtocolApplicationContext,
  InlineProtocolApplicationOperations,
} from "./application"
import { InlineProtocolAuthOperations } from "./auth"

export class InlineProtocolOperations implements InlineProtocolApplicationOperations {
  constructor(private readonly auth: InlineProtocolAuthOperations) {}

  authBegin(input: AuthBeginRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginResult> {
    return this.auth.begin(input, context)
  }

  authComplete(input: AuthCompleteRequest, context: InlineProtocolApplicationContext): Promise<AuthCompleteResult> {
    return this.auth.complete(input, context)
  }

  authBeginBrowser(input: AuthBeginBrowserRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginBrowserResult> {
    return this.auth.beginBrowser(input, context)
  }

  authBrowserStatus(input: AuthBrowserStatusRequest, context: InlineProtocolApplicationContext): Promise<AuthBrowserStatusResult> {
    return this.auth.browserStatus(input, context)
  }
}
