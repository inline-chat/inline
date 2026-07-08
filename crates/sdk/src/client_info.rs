//! Client identity and metadata helpers shared by HTTP and realtime clients.

use reqwest::header::{HeaderMap, HeaderValue};
use std::process::Command;
use thiserror::Error;

/// Default client type used when callers do not provide an application identity.
pub const SDK_CLIENT_TYPE: &str = "rust-sdk";
/// HTTP header carrying the Inline client type.
pub const CLIENT_TYPE_HEADER: &str = "x-inline-client-type";
/// HTTP header carrying the Inline client version.
pub const CLIENT_VERSION_HEADER: &str = "x-inline-client-version";

/// Error returned when a client identity cannot be represented in Inline headers.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
#[non_exhaustive]
pub enum ClientIdentityError {
    /// The given field is empty after trimming whitespace.
    #[error("{field} cannot be empty")]
    Empty {
        /// Name of the invalid identity field.
        field: &'static str,
    },
    /// The given field contains bytes rejected by `HeaderValue`.
    #[error("{field} contains characters that are invalid in HTTP headers")]
    InvalidHeaderValue {
        /// Name of the invalid identity field.
        field: &'static str,
    },
}

/// Application identity sent with Inline HTTP and realtime requests.
///
/// Use `ClientIdentity::sdk()` for low-level SDK callers, or pass your own
/// application-specific type such as `cli`, `matrix-bridge`, or `agent`.
#[must_use]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientIdentity {
    client_type: String,
    client_version: String,
}

impl ClientIdentity {
    /// Creates a client identity and panics if the values are invalid.
    ///
    /// This is intended for static or already-validated values. Use
    /// [`ClientIdentity::try_new`] when accepting user or config input.
    ///
    /// # Panics
    ///
    /// Panics when either field is empty after trimming or cannot be represented
    /// as an HTTP header value.
    pub fn new(
        client_type: impl Into<String>,
        client_version: impl Into<String>,
    ) -> ClientIdentity {
        Self::try_new(client_type, client_version).expect("client identity must be valid")
    }

    /// Creates a client identity after trimming and validating header values.
    pub fn try_new(
        client_type: impl Into<String>,
        client_version: impl Into<String>,
    ) -> Result<ClientIdentity, ClientIdentityError> {
        let client_type = normalize_header_component("client_type", client_type.into())?;
        let client_version = normalize_header_component("client_version", client_version.into())?;
        Ok(Self {
            client_type,
            client_version,
        })
    }

    /// Returns the default SDK identity for this crate version.
    pub fn sdk() -> ClientIdentity {
        ClientIdentity::new(SDK_CLIENT_TYPE, sdk_version())
    }

    /// Returns the Inline client type, such as `rust-sdk` or `cli`.
    pub fn client_type(&self) -> &str {
        &self.client_type
    }

    /// Returns the application version sent to Inline.
    pub fn client_version(&self) -> &str {
        &self.client_version
    }
}

impl Default for ClientIdentity {
    fn default() -> Self {
        Self::sdk()
    }
}

/// Login metadata sent with auth code and verification requests.
#[must_use]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthMetadata {
    device_id: String,
    device_name: Option<String>,
    client: ClientIdentity,
}

impl AuthMetadata {
    /// Creates auth metadata for a durable device id and client identity.
    pub fn new(device_id: impl Into<String>, client: ClientIdentity) -> Self {
        Self {
            device_id: device_id.into(),
            device_name: None,
            client,
        }
    }

    /// Creates auth metadata using the default SDK client identity.
    pub fn sdk(device_id: impl Into<String>) -> Self {
        Self::new(device_id, ClientIdentity::sdk())
    }

    /// Attaches a human-readable device name.
    pub fn with_device_name(mut self, device_name: impl Into<String>) -> Self {
        let device_name = device_name.into().trim().to_string();
        if !device_name.is_empty() {
            self.device_name = Some(device_name);
        }
        self
    }

    /// Returns the durable device id.
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    /// Returns the optional human-readable device name.
    pub fn device_name(&self) -> Option<&str> {
        self.device_name.as_deref()
    }

    /// Returns the client identity used for auth requests.
    pub fn client(&self) -> &ClientIdentity {
        &self.client
    }
}

/// Returns the version of the `inline-sdk` crate.
pub fn sdk_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Builds the default SDK user agent.
pub fn user_agent() -> String {
    user_agent_for(&ClientIdentity::sdk())
}

/// Builds a user agent for a specific client identity.
pub fn user_agent_for(identity: &ClientIdentity) -> String {
    format!("{}/{}", identity.client_type(), identity.client_version())
}

/// Returns a best-effort local device name.
pub fn device_name() -> Option<String> {
    hostname::get()
        .ok()
        .and_then(|name| name.into_string().ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
}

/// Builds default Inline HTTP headers for the SDK identity.
pub fn default_http_headers() -> HeaderMap {
    default_http_headers_for(&ClientIdentity::sdk())
}

/// Builds Inline HTTP headers for a specific client identity.
pub fn default_http_headers_for(identity: &ClientIdentity) -> HeaderMap {
    try_default_http_headers_for(identity).expect("validated client identity must fit HTTP headers")
}

/// Builds Inline HTTP headers for a specific client identity.
pub fn try_default_http_headers_for(
    identity: &ClientIdentity,
) -> Result<HeaderMap, ClientIdentityError> {
    let mut headers = HeaderMap::new();
    headers.insert(
        CLIENT_TYPE_HEADER,
        header_value("client_type", identity.client_type())?,
    );
    headers.insert(
        CLIENT_VERSION_HEADER,
        header_value("client_version", identity.client_version())?,
    );
    Ok(headers)
}

/// Builds a `reqwest` client builder configured with SDK identity headers.
pub fn http_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .default_headers(default_http_headers())
        .user_agent(user_agent())
}

/// Builds a `reqwest` client builder configured with a specific identity.
pub fn http_client_builder_for(identity: &ClientIdentity) -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .default_headers(default_http_headers_for(identity))
        .user_agent(user_agent_for(identity))
}

/// Returns a best-effort operating system version string for realtime init.
pub fn current_os_version() -> Option<String> {
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

fn normalize_header_component(
    field: &'static str,
    value: String,
) -> Result<String, ClientIdentityError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(ClientIdentityError::Empty { field });
    }
    HeaderValue::from_str(&value).map_err(|_| ClientIdentityError::InvalidHeaderValue { field })?;
    Ok(value)
}

fn header_value(field: &'static str, value: &str) -> Result<HeaderValue, ClientIdentityError> {
    HeaderValue::from_str(value).map_err(|_| ClientIdentityError::InvalidHeaderValue { field })
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::USER_AGENT;

    #[test]
    fn default_headers_identify_sdk_without_user_agent() {
        let headers = default_http_headers();
        assert_eq!(
            headers
                .get(CLIENT_TYPE_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some("rust-sdk")
        );
        assert_eq!(
            headers
                .get(CLIENT_VERSION_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some(sdk_version())
        );
        assert!(headers.get(USER_AGENT).is_none());
    }

    #[test]
    fn default_headers_can_use_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        let headers = default_http_headers_for(&identity);
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
    fn fallible_default_headers_can_use_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        let headers = try_default_http_headers_for(&identity).unwrap();
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
    }

    #[test]
    fn user_agent_identifies_sdk_version() {
        assert_eq!(user_agent(), format!("rust-sdk/{}", sdk_version()));
    }

    #[test]
    fn user_agent_can_use_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        assert_eq!(user_agent_for(&identity), "my-agent/0.1.0");
    }

    #[test]
    fn http_client_builder_builds_with_sdk_metadata() {
        assert!(http_client_builder().build().is_ok());
    }

    #[test]
    fn http_client_builder_builds_with_custom_client_identity() {
        let identity = ClientIdentity::new("my-agent", "0.1.0");
        assert!(http_client_builder_for(&identity).build().is_ok());
    }

    #[test]
    fn auth_metadata_stores_device_context() {
        let identity = ClientIdentity::new("agent", "0.1.0");
        let metadata = AuthMetadata::new("device-1", identity.clone()).with_device_name("mo-mac");
        assert_eq!(metadata.device_id(), "device-1");
        assert_eq!(metadata.device_name(), Some("mo-mac"));
        assert_eq!(metadata.client(), &identity);
    }

    #[test]
    fn auth_metadata_ignores_blank_device_name() {
        let metadata = AuthMetadata::sdk("device-1").with_device_name("  ");
        assert_eq!(metadata.device_id(), "device-1");
        assert_eq!(metadata.device_name(), None);
    }

    #[test]
    fn client_identity_rejects_empty_or_invalid_values() {
        assert_eq!(
            ClientIdentity::try_new("", "0.1.0").unwrap_err(),
            ClientIdentityError::Empty {
                field: "client_type"
            }
        );
        assert_eq!(
            ClientIdentity::try_new("agent", "0.1\n0").unwrap_err(),
            ClientIdentityError::InvalidHeaderValue {
                field: "client_version"
            }
        );
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
