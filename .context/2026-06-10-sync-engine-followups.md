# Sync Engine Followups

Context: June 2026 sync reliability work moved bucket catch-up toward a server-authoritative cursor model. The client now keeps realtime ordering strict, buffers future seqs, trusts server/catch-up pointers to skip gaps, and logs when delivered updates do not cover the advanced pointer.

## Followups

- Monitor `getUpdates trusting page cursor after filtering updates` and `trusting getUpdates pointer ahead of delivered updates` warnings after release. These should be rare and actionable; recurring patterns should become server-side inflation fixes or explicit skip/update types.
- Decide product policy for recent catch-up message presentation. Catch-up currently remains replay/reload-like; if users expect recent missed messages to animate like live messages, add a freshness-based UI publish mode instead of mixing that into sync ordering.
- Add aggregated telemetry for trusted pointer advances: bucket type, skipped count, delivered count, reason, and whether buffered realtime filled the skipped seqs.
- Audit server update producers so skipped records are intentional. Prefer explicit no-op/skip updates for expected non-material updates, and warnings for unexpected unsupported payloads.
- Add an integration-style test that simulates realtime gap + catch-up pointer + filtered server record across both server response shape and client bucket advancement.
- Revisit repair scope after telemetry. Chat snapshot repair is now fallback for non-empty/non-pointer failures; keep it bounded and avoid expanding repair into a general sync path unless logs prove it is needed.
- Review whether system/read/archive/membership updates need stronger post-skip refreshes than messages. Server-authoritative cursor is the right failure boundary, but structural state may deserve targeted refetches if skipped frequently.
