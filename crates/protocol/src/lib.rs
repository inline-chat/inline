//! Generated Rust protocol types for Inline.
//!
//! The [`proto`] module is generated from `proto/core.proto` at build time with
//! `prost`. Most application code should depend on `inline-sdk`; use this
//! crate directly when you need raw protocol messages or advanced transport
//! work.

#![warn(missing_docs)]

/// Protobuf-generated Inline protocol module.
pub mod proto {
    #![allow(
        clippy::doc_lazy_continuation,
        clippy::enum_variant_names,
        clippy::large_enum_variant,
        missing_docs
    )]

    include!(concat!(env!("OUT_DIR"), "/_.rs"));
}
