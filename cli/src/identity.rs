use std::path::Path;

use inline_protocol::secure::handshake::RsaPublicKey;
use inline_sdk::{
    AuthMetadata, ClientIdentity, InlineProtocolAuthorization, InlineProtocolPublicKey,
    InlineProtocolV3Connection, InlineProtocolV3Options, RealtimeClient, RealtimeError,
    client_info,
};
use serde::Deserialize;

pub const CLIENT_TYPE: &str = "cli";
pub const CLIENT_TYPE_HEADER: &str = client_info::CLIENT_TYPE_HEADER;
pub const CLIENT_VERSION_HEADER: &str = client_info::CLIENT_VERSION_HEADER;

pub fn client_identity() -> ClientIdentity {
    ClientIdentity::new(CLIENT_TYPE, env!("CARGO_PKG_VERSION"))
}

pub fn auth_metadata(device_id: impl Into<String>, device_name: Option<&str>) -> AuthMetadata {
    let metadata = AuthMetadata::new(device_id, client_identity());
    match device_name {
        Some(device_name) => metadata.with_device_name(device_name),
        None => metadata,
    }
}

pub fn client_type() -> &'static str {
    CLIENT_TYPE
}

pub fn client_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

pub fn user_agent() -> String {
    client_info::user_agent_for(&client_identity())
}

pub fn device_name() -> Option<String> {
    client_info::device_name()
}

pub fn http_client_builder() -> reqwest::ClientBuilder {
    client_info::http_client_builder_for(&client_identity())
}

pub fn current_os_version() -> Option<String> {
    client_info::current_os_version()
}

pub async fn connect_realtime(url: &str, token: &str) -> Result<RealtimeClient, RealtimeError> {
    RealtimeClient::builder(url, token)
        .identity(client_identity())
        .connect()
        .await
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublicRing {
    rsa_public_key_ring: Vec<InlineProtocolPublicKey>,
}

pub fn load_inline_protocol_public_ring(
    path: &Path,
) -> Result<Vec<RsaPublicKey>, Box<dyn std::error::Error>> {
    let ring: PublicRing = serde_json::from_slice(&std::fs::read(path)?)?;
    ring.rsa_public_key_ring
        .into_iter()
        .map(|key| key.try_into().map_err(Into::into))
        .collect()
}

pub async fn connect_inline_protocol_fresh(
    url: &str,
    keys: Vec<RsaPublicKey>,
    temporary: bool,
) -> Result<InlineProtocolV3Connection, inline_sdk::InlineProtocolV3Error> {
    let mut options = InlineProtocolV3Options::permanent(url, keys);
    options.temporary = temporary;
    InlineProtocolV3Connection::connect(options).await
}

pub async fn reconnect_inline_protocol(
    url: &str,
    authorization: InlineProtocolAuthorization,
) -> Result<InlineProtocolV3Connection, inline_sdk::InlineProtocolV3Error> {
    InlineProtocolV3Connection::connect(InlineProtocolV3Options::reconnect(url, authorization))
        .await
}
