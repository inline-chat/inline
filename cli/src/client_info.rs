use reqwest::header::{HeaderMap, HeaderValue};
use std::process::Command;

pub(crate) const CLIENT_TYPE: &str = "cli";
pub(crate) const CLIENT_TYPE_HEADER: &str = "x-inline-client-type";
pub(crate) const CLIENT_VERSION_HEADER: &str = "x-inline-client-version";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ClientIdentity<'a> {
    pub(crate) client_type: &'a str,
    pub(crate) client_version: &'a str,
}

impl<'a> ClientIdentity<'a> {
    pub(crate) fn new(client_type: &'a str, client_version: &'a str) -> Self {
        Self {
            client_type,
            client_version,
        }
    }

    pub(crate) fn cli() -> ClientIdentity<'static> {
        ClientIdentity::new(CLIENT_TYPE, client_version())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AuthMetadata<'a> {
    pub(crate) device_id: &'a str,
    pub(crate) device_name: Option<&'a str>,
    pub(crate) client: ClientIdentity<'a>,
}

impl<'a> AuthMetadata<'a> {
    pub(crate) fn new(
        device_id: &'a str,
        device_name: Option<&'a str>,
        client: ClientIdentity<'a>,
    ) -> Self {
        Self {
            device_id,
            device_name,
            client,
        }
    }

    pub(crate) fn cli(device_id: &'a str, device_name: Option<&'a str>) -> Self {
        Self::new(device_id, device_name, ClientIdentity::cli())
    }
}

pub(crate) fn client_type() -> &'static str {
    CLIENT_TYPE
}

pub(crate) fn client_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

pub(crate) fn user_agent() -> String {
    user_agent_for(ClientIdentity::cli())
}

pub(crate) fn user_agent_for(identity: ClientIdentity<'_>) -> String {
    if identity.client_type == CLIENT_TYPE {
        format!("inline-cli/{}", identity.client_version)
    } else {
        format!("{}/{}", identity.client_type, identity.client_version)
    }
}

pub(crate) fn device_name() -> Option<String> {
    hostname::get()
        .ok()
        .and_then(|name| name.into_string().ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
}

pub(crate) fn default_http_headers() -> HeaderMap {
    default_http_headers_for(ClientIdentity::cli())
}

pub(crate) fn default_http_headers_for(identity: ClientIdentity<'_>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if let Ok(value) = HeaderValue::from_str(identity.client_type) {
        headers.insert(CLIENT_TYPE_HEADER, value);
    }
    if let Ok(value) = HeaderValue::from_str(identity.client_version) {
        headers.insert(CLIENT_VERSION_HEADER, value);
    }
    headers
}

pub(crate) fn http_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .default_headers(default_http_headers())
        .user_agent(user_agent())
}

pub(crate) fn http_client_builder_for(identity: ClientIdentity<'_>) -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .default_headers(default_http_headers_for(identity))
        .user_agent(user_agent_for(identity))
}

pub(crate) fn current_os_version() -> Option<String> {
    let mut cmd = match std::env::consts::OS {
        "macos" => {
            let mut cmd = Command::new("sw_vers");
            cmd.arg("-productVersion");
            cmd
        }
        "linux" => {
            let mut cmd = Command::new("uname");
            cmd.arg("-r");
            cmd
        }
        "windows" => {
            let mut cmd = Command::new("cmd");
            cmd.args(["/C", "ver"]);
            cmd
        }
        _ => return Some(std::env::consts::OS.to_string()),
    };

    let output = cmd.output().ok()?;
    if !output.status.success() {
        return Some(std::env::consts::OS.to_string());
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return Some(std::env::consts::OS.to_string());
    }

    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::USER_AGENT;

    #[test]
    fn default_headers_identify_cli_without_user_agent() {
        let headers = default_http_headers();
        assert_eq!(
            headers
                .get(CLIENT_TYPE_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some("cli")
        );
        assert_eq!(
            headers
                .get(CLIENT_VERSION_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some(client_version())
        );
        assert!(headers.get(USER_AGENT).is_none());
    }

    #[test]
    fn default_headers_can_use_custom_client_identity() {
        let headers = default_http_headers_for(ClientIdentity::new("my-agent", "0.1.0"));
        assert_eq!(
            headers
                .get(CLIENT_TYPE_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some("my-agent")
        );
        assert_eq!(
            headers
                .get(CLIENT_VERSION_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some("0.1.0")
        );
        assert!(headers.get(USER_AGENT).is_none());
    }

    #[test]
    fn user_agent_identifies_cli_version() {
        assert_eq!(user_agent(), format!("inline-cli/{}", client_version()));
    }

    #[test]
    fn user_agent_can_use_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        assert_eq!(user_agent_for(identity), "my-agent/0.1.0");
    }

    #[test]
    fn http_client_builder_builds_with_cli_metadata() {
        assert!(http_client_builder().build().is_ok());
    }

    #[test]
    fn http_client_builder_builds_with_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        assert!(http_client_builder_for(identity).build().is_ok());
    }

    #[test]
    fn auth_metadata_stores_device_context() {
        let identity = ClientIdentity::new("agent", "0.1.0");
        let metadata = AuthMetadata::new("device-1", Some("mo-mac"), identity);
        assert_eq!(metadata.device_id, "device-1");
        assert_eq!(metadata.device_name, Some("mo-mac"));
        assert_eq!(metadata.client, identity);
    }

    #[test]
    fn device_name_is_never_empty() {
        assert!(
            device_name()
                .as_deref()
                .map(|name| !name.is_empty())
                .unwrap_or(true)
        );
    }
}
