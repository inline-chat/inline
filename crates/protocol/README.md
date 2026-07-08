# inline-protocol

Generated Rust protocol types for Inline.

This crate is intentionally small: it exposes the protobuf-generated `proto`
module used by higher-level crates such as `inline-sdk`. In the workspace, the
public protocol source is the repository `proto/core.proto`; the crate also
packages a matching `proto/core.proto` copy so published builds are
self-contained. Generated Rust code is produced at build time with `prost`.

Most application code should depend on `inline-sdk` rather than using this
crate directly.

When updating the public protocol, keep `proto/core.proto` identical to the
workspace `proto/core.proto` before packaging.
