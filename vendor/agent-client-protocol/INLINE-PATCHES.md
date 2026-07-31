# Inline security patches

This is the exact `agent-client-protocol` 2.0.0 crate source pinned by the
workspace. Inline carries two fail-closed transport changes until an equivalent
upstream API is available:

- ACP subprocess stdout is decoded with a 1 MiB maximum frame size before a
  complete `String` is allocated.
- JSON-RPC component channels hold at most 64 complete frames and apply
  backpressure between async transport actors. Synchronous senders fail when
  the queue is full instead of allocating without a limit.

Protocol schemas and public ACP behavior are otherwise unchanged. The upstream
crate license remains Apache-2.0.
