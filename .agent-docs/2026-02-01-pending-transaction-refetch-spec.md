# Pending Transaction Refetch Guard (Draft)

## Goal
Prevent refetch results from overwriting optimistic/local changes by coordinating refetch application with pending transactions.

## Proposal
- Allow transactions to optionally register which nodes (type + id + fields) they mutate.
- Add a refetch tool that optionally declares which nodes it will touch.
- When applying refetch results, check pending transactions for those nodes/fields:
  - If a pending transaction exists, hold or merge refetch data for those fields.
  - If server data matches the pending value, clear pending for that field.
- Implement timeouts to avoid blocking forever if a transaction fails or stalls.

## Notes / Guardrails
- Gate at **apply/commit time**, not only at request start, to avoid race overwrites.
- Track pending at **field granularity** (or category) so unrelated fields keep updating.
- Start with Dialog/Chat, expand as needed.

## Incremental Adoption
1. Add registry + pending entries for a single dialog field (e.g., archived).
2. Add refetch tool for chats/dialogs; apply-time merge/skip.
3. Expand to other fields or models only when needed.
