# Encryption Hardening Plan (Phase 2 and Phase 3)

Date: 2026-02-17
Owner: Server team
Status: Planned

## Scope

This plan covers deferred work after immediate hardening is complete:
- Phase 2: cryptography architecture and key lifecycle hardening
- Phase 3: infrastructure-level data protection and advanced metadata protection

## Phase 2: Crypto Architecture Hardening

### 1. Introduce versioned encryption envelope

Goal:
- Replace ad-hoc `(iv, tag, ciphertext)` storage conventions with a single versioned envelope format.

Tasks:
1. Add a shared envelope encoder/decoder in `server/src/modules/encryption/`.
2. Envelope fields:
   - `version`
   - `keyId`
   - `algorithm`
   - `iv`
   - `authTag`
   - `ciphertext`
3. Keep backward compatibility readers for existing v1/v2 payloads.
4. New writes use only the new envelope.

Acceptance criteria:
- New writes include envelope version/keyId.
- Existing rows decrypt without migration-time breakage.

### 2. Add keyring + rotation support

Goal:
- Support active key + legacy keys for rolling rotation without downtime.

Tasks:
1. Introduce keyring config in env/secret manager:
   - active key id
   - map of `keyId -> key`
2. Decrypt path selects key by `keyId`.
3. Encrypt path always uses active key.
4. Add rotation runbook and guardrails.

Acceptance criteria:
- Can rotate active key without blocking reads.
- Old ciphertext remains readable during transition.

### 3. Bind ciphertext with AAD

Goal:
- Prevent ciphertext relocation attacks across columns/records.

Tasks:
1. Define AAD schema: `table|column|record-id|version`.
2. Apply AAD on encrypt and decrypt for all sensitive domains.
3. Add tests for relocation/tampering failure.

Acceptance criteria:
- Swapping ciphertext between records/fields fails auth tag verification.

### 4. Consistency and migration tooling

Goal:
- Ensure all encryption call sites converge on one API.

Tasks:
1. Deprecate direct usage of `encryption.ts` and `encryption2.ts` public primitives in business logic.
2. Introduce domain-specific wrappers with fixed AAD context.
3. Add a migration worker to re-encrypt legacy rows into envelope format.
4. Add metrics for migration coverage and decrypt failures per domain.

Acceptance criteria:
- All target tables moved to the envelope API.
- Migration progress observable and resumable.

## Phase 3: Platform/Storage Hardening

### 1. KMS-backed envelope encryption

Goal:
- Remove long-lived plaintext data-encryption keys from app env where possible.

Tasks:
1. Integrate with KMS/HSM (provider decision pending).
2. Use DEKs for row/domain encryption; wrap DEKs with KMS KEK.
3. Cache unwrapped DEKs with strict TTL and eviction strategy.
4. Document outage/degraded-mode behavior.

Acceptance criteria:
- Encryption root trust anchored in KMS, not static app env alone.

### 2. Object storage encryption hardening

Goal:
- Protect file bytes independently from application database compromise.

Tasks:
1. Enforce SSE-KMS/CMEK at bucket policy level (minimum baseline).
2. Evaluate app-layer content encryption for high-sensitivity file classes.
3. Ensure presigned URL policies match new storage protection model.

Acceptance criteria:
- File bytes encrypted with managed keys and enforced by policy.
- Access paths audited.

### 3. Metadata confidentiality uplift

Goal:
- Reduce plaintext metadata blast radius while preserving product behavior.

Tasks:
1. Prioritize sensitive metadata columns for encryption:
   - `dialogs.draft`
   - selected user/chat/space fields based on threat model
2. Where queryability is required, add blind indexes or tokenized search fields.
3. Add migration strategy and fallback readers.

Acceptance criteria:
- Target metadata fields no longer exposed in plaintext DB dumps.
- Required lookup queries remain functional.

## Cross-cutting quality gates

1. Add security-focused tests:
   - tamper detection
   - wrong-key failures
   - AAD mismatch failures
   - backward compatibility decrypt tests
2. Add observability:
   - decrypt failure counters by domain/version/keyId
   - key rotation health dashboards
3. Add incident-response playbooks:
   - key compromise
   - emergency rotation
   - migration rollback/freeze

## Execution order

1. Phase 2.1 envelope
2. Phase 2.2 keyring
3. Phase 2.3 AAD
4. Phase 2.4 migration tooling
5. Phase 3.1 KMS
6. Phase 3.2 object encryption
7. Phase 3.3 metadata uplift

## Notes

- Immediate fixes are intentionally separate and should land first.
- Phase 2/3 changes should be rolled out with dual-read + single-write patterns to avoid downtime.
