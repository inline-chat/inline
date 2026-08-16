import type {
  EstablishedAuthorizationKey,
  LoadedServerAuthorizationKey,
  ServerAuthorizationKeyRepository,
} from "@inline-chat/protocol/server"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"

export class InlineProtocolAuthorizationKeys implements ServerAuthorizationKeyRepository {
  constructor(
    private readonly permanent: PermanentAuthorizationKeyRepository,
    private readonly temporary: TemporaryAuthorizationKeyStore,
  ) {}

  create(key: EstablishedAuthorizationKey): Promise<"created" | "collision"> {
    return key.temporary ? this.temporary.create(key) : this.permanent.create(key)
  }

  async load(authKeyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined> {
    const temporary = this.temporary.get(authKeyId)
    if (temporary) {
      if (temporary.binding) {
        const permanent = await this.permanent.getActive(temporary.binding.permanentAuthKeyId)
        if (!permanent || permanent.userId !== temporary.binding.userId ||
            permanent.accountSessionId !== temporary.binding.accountSessionId) {
          this.temporary.revoke(authKeyId)
          return undefined
        }
      }
      return {
        key: temporary.key,
        keyId: temporary.keyId,
        temporary: true,
        expiresAt: temporary.expiresAt,
        currentServerSalt: temporary.serverSalt,
        binding: temporary.binding ? {
          permanentAuthKeyId: temporary.binding.permanentAuthKeyId,
          temporarySessionId: temporary.binding.temporarySessionId,
          nonce: temporary.binding.nonce,
          expiresAt: temporary.binding.expiresAt,
          userId: temporary.binding.userId,
          accountSessionId: temporary.binding.accountSessionId,
        } : undefined,
      }
    }
    const permanent = await this.permanent.getActive(authKeyId)
    if (!permanent) return undefined
    return {
      key: permanent.key,
      keyId: permanent.keyId,
      temporary: false,
      currentServerSalt: permanent.currentServerSalt,
      previousServerSalt: permanent.previousServerSalt,
      authorized: permanent.userId !== undefined && permanent.accountSessionId !== undefined
        ? { userId: permanent.userId, accountSessionId: permanent.accountSessionId }
        : undefined,
    }
  }

  async bindTemporary(input: {
    temporaryAuthKeyId: Uint8Array
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }): Promise<"created" | "idempotent" | "conflict"> {
    return this.temporary.bind(input.temporaryAuthKeyId, {
      permanentAuthKeyId: input.permanentAuthKeyId,
      temporarySessionId: input.temporarySessionId,
      nonce: input.nonce,
      expiresAt: input.expiresAt,
      userId: input.userId,
      accountSessionId: input.accountSessionId,
    })
  }

  async revokePermanent(authKeyId: Uint8Array): Promise<boolean> {
    const revoked = await this.permanent.revoke(authKeyId)
    if (revoked) this.temporary.revokePermanent(authKeyId)
    return revoked
  }

  async rotateServerSalt(authKeyId: Uint8Array, newServerSalt: bigint): Promise<boolean> {
    return this.temporary.rotateServerSalt(authKeyId, newServerSalt) ||
      this.permanent.rotateServerSalt(authKeyId, newServerSalt)
  }

  async revoke(authKeyId: Uint8Array): Promise<boolean> {
    if (this.temporary.revoke(authKeyId)) return true
    return this.revokePermanent(authKeyId)
  }

  clearTemporary(): void {
    this.temporary.clear()
  }
}
