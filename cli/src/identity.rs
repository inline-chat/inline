use std::path::Path;

use inline_protocol::secure::handshake::RsaPublicKey;
use inline_sdk::{
    AuthMetadata, ClientIdentity, InlineProtocolAuthorization, InlineProtocolPublicKey,
    InlineProtocolV3Connection, InlineProtocolV3Options, RealtimeClient, RealtimeError,
    client_info, inline_protocol_production_public_key_ring,
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

pub fn load_inline_protocol_public_key_ring(
    path: &Path,
) -> Result<Vec<InlineProtocolPublicKey>, Box<dyn std::error::Error>> {
    parse_inline_protocol_public_key_ring(&std::fs::read(path)?)
}

pub fn resolve_inline_protocol_public_ring() -> Result<Vec<RsaPublicKey>, Box<dyn std::error::Error>>
{
    resolve_inline_protocol_public_key_ring()?
        .into_iter()
        .map(|key| key.try_into().map_err(Into::into))
        .collect()
}

pub fn resolve_inline_protocol_public_key_ring()
-> Result<Vec<InlineProtocolPublicKey>, Box<dyn std::error::Error>> {
    match std::env::var_os("INLINE_PROTOCOL_PUBLIC_RING") {
        Some(path) => load_inline_protocol_public_key_ring(Path::new(&path)),
        None => inline_protocol_production_public_key_ring().map_err(Into::into),
    }
}

fn parse_inline_protocol_public_key_ring(
    bytes: &[u8],
) -> Result<Vec<InlineProtocolPublicKey>, Box<dyn std::error::Error>> {
    let ring: PublicRing = serde_json::from_slice(bytes)?;
    for key in ring.rsa_public_key_ring.iter().cloned() {
        let _: RsaPublicKey = key.try_into()?;
    }
    Ok(ring.rsa_public_key_ring)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_production_ring_is_valid_and_contains_rotation_overlap() {
        let ring = inline_protocol_production_public_key_ring().unwrap();
        assert_eq!(ring.len(), 2);
        assert_eq!(ring[0].fingerprint, "-8339382514522710386");
        assert_eq!(ring[1].fingerprint, "-3957383261870667958");
    }
}
