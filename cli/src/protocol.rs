pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/_.rs"));

    pub mod client {
        include!(concat!(env!("OUT_DIR"), "/client.rs"));
    }

    pub mod server {
        include!(concat!(env!("OUT_DIR"), "/server.rs"));
    }
}
