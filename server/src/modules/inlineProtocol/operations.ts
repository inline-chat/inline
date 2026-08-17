import type {
  AuthBeginRequest,
  AuthBeginResult,
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
}
