pub mod proto {
    #![allow(
        clippy::doc_lazy_continuation,
        clippy::enum_variant_names,
        clippy::large_enum_variant
    )]

    include!(concat!(env!("OUT_DIR"), "/_.rs"));
}
