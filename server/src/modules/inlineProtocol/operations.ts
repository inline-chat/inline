import type {
  AuthBeginRequest,
  AuthBeginResult,
  AuthCompleteRequest,
  AuthCompleteResult,
  CreateHttpUploadRequest,
  CreateHttpUploadResult,
  FinishHttpUploadRequest,
  FinishHttpUploadResult,
} from "@inline-chat/protocol/core"
import type {
  InlineProtocolApplicationContext,
  InlineProtocolApplicationOperations,
} from "./application"
import { InlineProtocolAuthOperations } from "./auth"
import { InlineProtocolUploadOperations } from "./uploads"

export class InlineProtocolOperations implements InlineProtocolApplicationOperations {
  constructor(
    private readonly auth: InlineProtocolAuthOperations,
    readonly uploads: InlineProtocolUploadOperations,
  ) {}

  authBegin(input: AuthBeginRequest, context: InlineProtocolApplicationContext): Promise<AuthBeginResult> {
    return this.auth.begin(input, context)
  }

  authComplete(input: AuthCompleteRequest, context: InlineProtocolApplicationContext): Promise<AuthCompleteResult> {
    return this.auth.complete(input, context)
  }

  createHttpUpload(
    input: CreateHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<CreateHttpUploadResult> {
    return this.uploads.create(input, context)
  }

  finishHttpUpload(
    input: FinishHttpUploadRequest,
    context: InlineProtocolApplicationContext,
  ): Promise<FinishHttpUploadResult> {
    return this.uploads.finish(input, context)
  }
}
