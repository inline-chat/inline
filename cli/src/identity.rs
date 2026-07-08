use inline_sdk::{AuthMetadata, ClientIdentity, RealtimeClient, RealtimeError, client_info};

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
