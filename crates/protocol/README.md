# inline-protocol

Inline Schema types and portable Inline Protocol v1 primitives for Rust.

The crate exposes the protobuf-generated `proto` module used by higher-level
crates such as `inline-sdk`, plus the MTProto 2.0-compatible `secure` module for
RSA_PAD/DH, encrypted records, Inline application constructors, abridged quick
ACK framing, and bounded receive-window behavior. In the workspace, the public
schema source is `proto/core.proto`; the crate also packages a matching copy so
published builds are self-contained. Generated Rust code is produced at build
time with `prost`.

Most application code should depend on `inline-sdk` rather than using this
crate directly.

When updating the public protocol, keep `proto/core.proto` identical to the
workspace `proto/core.proto` before packaging.
