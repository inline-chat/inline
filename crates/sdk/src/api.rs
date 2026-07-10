//! HTTP API helpers for auth, uploads, and selected REST-style Inline endpoints.

use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fmt;
use std::fs;
use std::path::PathBuf;
use std::str::FromStr;
use std::time::Duration;
use thiserror::Error;
use url::Url;

use crate::client_info::{self, AuthMetadata, ClientIdentity};

/// Default timeout for API HTTP requests made by SDK-created clients.
pub const DEFAULT_API_TIMEOUT: Duration = Duration::from_secs(60);
const DEFAULT_AUTH_SESSION_CLIENT_TYPE: &str = "api";

/// Error returned by [`ApiClient`] HTTP calls.
#[derive(Error)]
#[non_exhaustive]
pub enum ApiError {
    /// Invalid Inline API base URL supplied to an API client builder.
    #[error("invalid API base URL: {message}")]
    InvalidBaseUrl {
        /// Original URL value supplied by the caller.
        url: String,
        /// Human-readable validation failure.
        message: String,
    },
    /// A network, TLS, redirect, or HTTP client error from `reqwest`.
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    /// Local file system error, currently used when reading upload inputs.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    /// JSON encoding or decoding error.
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    /// SDK input validation error before sending a request.
    #[error("invalid input: {message}")]
    InvalidInput {
        /// Human-readable validation failure.
        message: String,
    },
    /// Non-success HTTP status where the body could not be decoded as an Inline error.
    #[error("api request failed with HTTP {status}: {message}")]
    Status {
        /// HTTP status code.
        status: u16,
        /// Human-readable HTTP status text.
        message: String,
        /// Short normalized response-body preview, when available.
        body: Option<String>,
    },
    /// Inline API error decoded from a structured response body.
    #[error("api error: {error}: {description}")]
    Api {
        /// HTTP status code, when the error came from an HTTP response.
        status: Option<u16>,
        /// Stable server error name or fallback error label.
        error: String,
        /// Numeric server error code, when provided.
        error_code: Option<i32>,
        /// Human-readable error description.
        description: String,
    },
}

impl fmt::Debug for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::InvalidBaseUrl { url, message } => f
                .debug_struct("InvalidBaseUrl")
                .field("url", &api_base_url_for_debug(url))
                .field("message", message)
                .finish(),
            ApiError::Http(error) => f.debug_tuple("Http").field(error).finish(),
            ApiError::Io(error) => f.debug_tuple("Io").field(error).finish(),
            ApiError::Json(error) => f.debug_tuple("Json").field(error).finish(),
            ApiError::InvalidInput { message } => f
                .debug_struct("InvalidInput")
                .field("message", message)
                .finish(),
            ApiError::Status {
                status,
                message,
                body,
            } => f
                .debug_struct("Status")
                .field("status", status)
                .field("message", message)
                .field("body", body)
                .finish(),
            ApiError::Api {
                status,
                error,
                error_code,
                description,
            } => f
                .debug_struct("Api")
                .field("status", status)
                .field("error", error)
                .field("error_code", error_code)
                .field("description", description)
                .finish(),
        }
    }
}

/// Thin HTTP client for Inline API endpoints.
#[must_use]
#[derive(Clone)]
pub struct ApiClient {
    base_url: String,
    http: Client,
    request_timeout: Option<Duration>,
}

impl fmt::Debug for ApiClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApiClient")
            .field("base_url", &self.base_url)
            .field("http", &"<reqwest::Client>")
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

/// Builder for [`ApiClient`].
#[must_use]
#[derive(Clone)]
pub struct ApiClientBuilder {
    base_url: String,
    identity: ClientIdentity,
    http: Option<Client>,
    request_timeout: Option<Duration>,
}

impl fmt::Debug for ApiClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApiClientBuilder")
            .field("base_url", &api_base_url_for_debug(&self.base_url))
            .field("identity", &self.identity)
            .field(
                "http",
                &self.http.as_ref().map(|_| "<custom reqwest::Client>"),
            )
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

impl ApiClient {
    /// Starts an [`ApiClient`] builder for an Inline API base URL.
    pub fn builder(base_url: impl Into<String>) -> ApiClientBuilder {
        ApiClientBuilder::new(base_url)
    }

    /// Creates an API client with the default SDK identity.
    pub fn try_new(base_url: impl Into<String>) -> Result<Self, ApiError> {
        Self::builder(base_url).build()
    }

    /// Creates an API client with a custom client identity.
    pub fn try_new_with_identity(
        base_url: impl Into<String>,
        identity: ClientIdentity,
    ) -> Result<Self, ApiError> {
        Self::builder(base_url).identity(identity).build()
    }

    /// Returns the normalized API base URL.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Returns the underlying `reqwest` client.
    pub fn http_client(&self) -> &Client {
        &self.http
    }

    /// Returns the request timeout configured by the SDK builder.
    ///
    /// This is `None` when the caller provided a custom `reqwest` client.
    pub fn request_timeout(&self) -> Option<Duration> {
        self.request_timeout
    }
}

impl ApiClientBuilder {
    /// Creates a builder with the default SDK identity.
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            identity: ClientIdentity::sdk(),
            http: None,
            request_timeout: Some(DEFAULT_API_TIMEOUT),
        }
    }

    /// Sets the client identity used for default HTTP headers and user agent.
    pub fn identity(mut self, identity: ClientIdentity) -> Self {
        self.identity = identity;
        self
    }

    /// Uses a caller-provided `reqwest` client.
    ///
    /// When this is set, the SDK does not inject identity headers into that
    /// client and does not apply request timeout settings; configure them
    /// before passing the client if needed.
    pub fn http_client(mut self, http: Client) -> Self {
        self.http = Some(http);
        self
    }

    /// Sets the timeout for API HTTP requests made by SDK-created clients.
    pub fn request_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = Some(timeout);
        self
    }

    /// Disables the SDK default API request timeout.
    pub fn without_request_timeout(mut self) -> Self {
        self.request_timeout = None;
        self
    }

    /// Builds the API client.
    pub fn build(self) -> Result<ApiClient, ApiError> {
        let base_url = normalize_api_base_url(self.base_url)?;
        log::debug!(
            target: "inline_sdk::api",
            "building API client base_url={base_url} identity_type={} request_timeout={:?} custom_http_client={}",
            self.identity.client_type(),
            self.request_timeout,
            self.http.is_some()
        );
        let (http, request_timeout) = match self.http {
            Some(http) => (http, None),
            None => {
                let mut builder = client_info::http_client_builder_for(&self.identity);
                if let Some(timeout) = self.request_timeout {
                    builder = builder.timeout(timeout);
                }
                (builder.build()?, self.request_timeout)
            }
        };
        Ok(ApiClient {
            base_url,
            http,
            request_timeout,
        })
    }
}

impl ApiClient {
    /// Creates an API client from a caller-provided `reqwest` client.
    pub fn try_with_http_client(
        base_url: impl Into<String>,
        http: Client,
    ) -> Result<Self, ApiError> {
        Ok(Self {
            base_url: normalize_api_base_url(base_url)?,
            http,
            request_timeout: None,
        })
    }

    /// Sends an email login code.
    pub async fn send_email_code(
        &self,
        email: &str,
        metadata: &AuthMetadata,
    ) -> Result<SendCodeResult, ApiError> {
        validate_required_str("email", email)?;
        validate_auth_metadata(metadata)?;
        let url = format!("{}/sendEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    /// Verifies an email login code and returns an auth token on success.
    pub async fn verify_email_code(
        &self,
        email: &str,
        code: &str,
        challenge_token: Option<&str>,
        metadata: &AuthMetadata,
    ) -> Result<VerifyCodeResult, ApiError> {
        validate_required_str("email", email)?;
        validate_required_str("verification code", code)?;
        validate_auth_metadata(metadata)?;
        let url = format!("{}/verifyEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        payload.insert("code".to_string(), json!(code));
        if let Some(challenge_token) =
            challenge_token.filter(|challenge_token| !challenge_token.trim().is_empty())
        {
            payload.insert("challengeToken".to_string(), json!(challenge_token));
        }
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    /// Sends an SMS login code.
    pub async fn send_sms_code(
        &self,
        phone_number: &str,
        metadata: &AuthMetadata,
    ) -> Result<SendCodeResult, ApiError> {
        validate_required_str("phone number", phone_number)?;
        validate_auth_metadata(metadata)?;
        let url = format!("{}/sendSmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    /// Verifies an SMS login code and returns an auth token on success.
    pub async fn verify_sms_code(
        &self,
        phone_number: &str,
        code: &str,
        metadata: &AuthMetadata,
    ) -> Result<VerifyCodeResult, ApiError> {
        validate_required_str("phone number", phone_number)?;
        validate_required_str("verification code", code)?;
        validate_auth_metadata(metadata)?;
        let url = format!("{}/verifySmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        payload.insert("code".to_string(), json!(code));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    /// Uploads a local file using the Inline upload endpoint.
    pub async fn upload_file(
        &self,
        token: &str,
        input: UploadFileInput,
    ) -> Result<UploadFileResult, ApiError> {
        validate_bearer_token(token)?;
        validate_upload_file_input(&input)?;
        let UploadFileInput {
            path,
            file_name,
            mime_type,
            file_type,
            video_metadata,
        } = input;
        let bytes = fs::read(&path)?;
        self.upload_file_bytes(
            token,
            UploadFileBytesInput {
                bytes,
                file_name,
                mime_type,
                file_type,
                video_metadata,
            },
        )
        .await
    }

    /// Uploads file bytes using the Inline upload endpoint.
    pub async fn upload_file_bytes(
        &self,
        token: &str,
        input: UploadFileBytesInput,
    ) -> Result<UploadFileResult, ApiError> {
        validate_bearer_token(token)?;
        validate_upload_file_bytes_input(&input)?;
        let url = format!("{}/uploadFile", self.base_url);
        log::debug!(
            target: "inline_sdk::api",
            "uploading file bytes type={} size_bytes={} has_mime_type={} has_video_metadata={}",
            input.file_type,
            input.bytes.len(),
            input.mime_type.is_some(),
            input.video_metadata.is_some()
        );
        let mut form = reqwest::multipart::Form::new().text("type", input.file_type.as_str());
        let mut file_part = reqwest::multipart::Part::bytes(input.bytes);
        file_part = file_part.file_name(input.file_name);
        if let Some(mime) = input.mime_type {
            file_part = file_part.mime_str(&mime)?;
        }
        form = form.part("file", file_part);

        if let Some(video) = input.video_metadata {
            form = form
                .text("width", video.width.to_string())
                .text("height", video.height.to_string())
                .text("duration", video.duration.to_string());
        }

        let response = self
            .http
            .post(url)
            .bearer_auth(token)
            .multipart(form)
            .send()
            .await?;
        log::trace!(
            target: "inline_sdk::api",
            "uploadFile response status={}",
            response.status()
        );
        decode_api_response(response).await
    }

    /// Marks messages as read for a peer.
    pub async fn read_messages(
        &self,
        token: &str,
        input: ReadMessagesInput,
    ) -> Result<ReadMessagesResult, ApiError> {
        validate_bearer_token(token)?;
        validate_peer_id(input.peer)?;
        if let Some(max_id) = input.max_id {
            validate_positive_id("max_id", max_id)?;
        }
        let url = format!("{}/readMessages", self.base_url);
        let mut payload = serde_json::Map::new();
        add_peer_selector_fields(&mut payload, input.peer);
        if let Some(max_id) = input.max_id {
            payload.insert("maxId".to_string(), json!(max_id));
        }
        self.post_with_token(url, token, payload).await
    }

    /// Creates or opens a private chat with a user.
    pub async fn create_private_chat(
        &self,
        token: &str,
        user_id: i64,
    ) -> Result<CreatePrivateChatResult, ApiError> {
        validate_bearer_token(token)?;
        validate_positive_id("user_id", user_id)?;
        let url = format!("{}/createPrivateChat", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("userId".to_string(), json!(user_id));
        self.post_with_token(url, token, payload).await
    }

    /// Revokes the current authenticated API session.
    pub async fn logout(&self, token: &str) -> Result<(), ApiError> {
        validate_bearer_token(token)?;
        let url = format!("{}/logout", self.base_url);
        let _: Value = self
            .post_with_token(url, token, serde_json::Map::new())
            .await?;
        Ok(())
    }

    /// Creates a Linear issue from an Inline message.
    pub async fn create_linear_issue(
        &self,
        token: &str,
        input: CreateLinearIssueInput,
    ) -> Result<CreateLinearIssueResult, ApiError> {
        validate_bearer_token(token)?;
        validate_create_linear_issue_input(&input)?;
        let url = format!("{}/createLinearIssue", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("text".to_string(), json!(input.text));
        payload.insert("messageId".to_string(), json!(input.message_id));
        payload.insert("chatId".to_string(), json!(input.chat_id));
        payload.insert("fromId".to_string(), json!(input.from_id));

        payload.insert("peerId".to_string(), json!(peer_id_object(input.peer)));

        if let Some(space_id) = input.space_id {
            payload.insert("spaceId".to_string(), json!(space_id));
        }

        self.post_with_token(url, token, payload).await
    }

    /// Creates a Notion task from an Inline message.
    pub async fn create_notion_task(
        &self,
        token: &str,
        input: CreateNotionTaskInput,
    ) -> Result<CreateNotionTaskResult, ApiError> {
        validate_bearer_token(token)?;
        validate_create_notion_task_input(&input)?;
        let url = format!("{}/createNotionTask", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("spaceId".to_string(), json!(input.space_id));
        payload.insert("messageId".to_string(), json!(input.message_id));
        payload.insert("chatId".to_string(), json!(input.chat_id));

        payload.insert("peerId".to_string(), json!(peer_id_object(input.peer)));

        self.post_with_token(url, token, payload).await
    }

    async fn post<T: for<'de> Deserialize<'de>>(
        &self,
        url: String,
        payload: serde_json::Map<String, serde_json::Value>,
    ) -> Result<T, ApiError> {
        log::trace!(
            target: "inline_sdk::api",
            "POST {}",
            api_url_path_for_log(&url)
        );
        let response = self.http.post(url).json(&payload).send().await?;
        log::trace!(
            target: "inline_sdk::api",
            "API response status={}",
            response.status()
        );
        decode_api_response(response).await
    }

    async fn post_with_token<T: for<'de> Deserialize<'de>>(
        &self,
        url: String,
        token: &str,
        payload: serde_json::Map<String, serde_json::Value>,
    ) -> Result<T, ApiError> {
        log::trace!(
            target: "inline_sdk::api",
            "POST {} with bearer auth",
            api_url_path_for_log(&url)
        );
        let response = self
            .http
            .post(url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await?;
        log::trace!(
            target: "inline_sdk::api",
            "API response status={}",
            response.status()
        );
        decode_api_response(response).await
    }
}

/// Response from sending an auth code.
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SendCodeResult {
    /// Whether the contact belongs to an existing user.
    pub existing_user: bool,
    /// Whether the login flow requires an invite code.
    pub needs_invite_code: bool,
    /// Challenge token required by some email verification flows.
    pub challenge_token: Option<String>,
}

impl fmt::Debug for SendCodeResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendCodeResult")
            .field("existing_user", &self.existing_user)
            .field("needs_invite_code", &self.needs_invite_code)
            .field(
                "challenge_token",
                &self.challenge_token.as_ref().map(|_| "<redacted>"),
            )
            .finish()
    }
}

/// Successful auth verification response.
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VerifyCodeResult {
    /// Inline user id.
    pub user_id: i64,
    /// Bearer token for authenticated API and realtime calls.
    pub token: String,
}

impl fmt::Debug for VerifyCodeResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VerifyCodeResult")
            .field("user_id", &self.user_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// Upload type accepted by the Inline upload endpoint.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[serde(rename_all = "lowercase")]
pub enum UploadFileType {
    /// Photo/image upload.
    Photo,
    /// Video upload.
    Video,
    /// Generic document upload.
    Document,
}

impl UploadFileType {
    /// Returns the wire-format upload type string.
    pub fn as_str(&self) -> &'static str {
        match self {
            UploadFileType::Photo => "photo",
            UploadFileType::Video => "video",
            UploadFileType::Document => "document",
        }
    }
}

impl fmt::Display for UploadFileType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for UploadFileType {
    type Err = UploadFileTypeParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.trim().to_ascii_lowercase().as_str() {
            "photo" => Ok(UploadFileType::Photo),
            "video" => Ok(UploadFileType::Video),
            "document" => Ok(UploadFileType::Document),
            _ => Err(UploadFileTypeParseError {
                value: value.to_string(),
            }),
        }
    }
}

/// Error returned when parsing an [`UploadFileType`] from a string.
#[derive(Debug, Clone, Error, PartialEq, Eq)]
#[error("unknown upload file type `{value}`")]
pub struct UploadFileTypeParseError {
    /// Original value that could not be parsed.
    pub value: String,
}

/// Video metadata sent with video uploads.
#[must_use]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UploadVideoMetadata {
    /// Video width in pixels.
    pub width: i32,
    /// Video height in pixels.
    pub height: i32,
    /// Video duration in seconds.
    pub duration: i32,
}

impl UploadVideoMetadata {
    /// Creates video metadata for a video upload.
    pub fn new(width: i32, height: i32, duration: i32) -> Self {
        Self {
            width,
            height,
            duration,
        }
    }
}

/// Local file upload input.
#[must_use]
#[derive(Clone, PartialEq, Eq)]
pub struct UploadFileInput {
    /// Local path to read and upload.
    pub path: PathBuf,
    /// File name reported to the server.
    pub file_name: String,
    /// Optional MIME type override.
    pub mime_type: Option<String>,
    /// Inline upload category.
    pub file_type: UploadFileType,
    /// Required video details when uploading a video.
    pub video_metadata: Option<UploadVideoMetadata>,
}

impl fmt::Debug for UploadFileInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadFileInput")
            .field("path", &"<redacted>")
            .field("file_name", &self.file_name)
            .field("mime_type", &self.mime_type)
            .field("file_type", &self.file_type)
            .field("video_metadata", &self.video_metadata)
            .finish()
    }
}

impl UploadFileInput {
    /// Creates an upload input with an explicit upload type.
    pub fn new(
        path: impl Into<PathBuf>,
        file_name: impl Into<String>,
        file_type: UploadFileType,
    ) -> Self {
        Self {
            path: path.into(),
            file_name: file_name.into(),
            mime_type: None,
            file_type,
            video_metadata: None,
        }
    }

    /// Creates a photo upload input.
    pub fn photo(path: impl Into<PathBuf>, file_name: impl Into<String>) -> Self {
        Self::new(path, file_name, UploadFileType::Photo)
    }

    /// Creates a video upload input with video metadata.
    pub fn video(
        path: impl Into<PathBuf>,
        file_name: impl Into<String>,
        metadata: UploadVideoMetadata,
    ) -> Self {
        Self::new(path, file_name, UploadFileType::Video).with_video_metadata(metadata)
    }

    /// Creates a generic document upload input.
    pub fn document(path: impl Into<PathBuf>, file_name: impl Into<String>) -> Self {
        Self::new(path, file_name, UploadFileType::Document)
    }

    /// Sets a MIME type override.
    pub fn with_mime_type(mut self, mime_type: impl Into<String>) -> Self {
        let mime_type = mime_type.into().trim().to_string();
        if !mime_type.is_empty() {
            self.mime_type = Some(mime_type);
        }
        self
    }

    /// Sets video metadata for a video upload.
    pub fn with_video_metadata(mut self, metadata: UploadVideoMetadata) -> Self {
        self.video_metadata = Some(metadata);
        self
    }
}

/// In-memory file upload input.
#[must_use]
#[derive(Clone, PartialEq, Eq)]
pub struct UploadFileBytesInput {
    /// File bytes to upload.
    pub bytes: Vec<u8>,
    /// File name reported to the server.
    pub file_name: String,
    /// Optional MIME type override.
    pub mime_type: Option<String>,
    /// Inline upload category.
    pub file_type: UploadFileType,
    /// Required video details when uploading a video.
    pub video_metadata: Option<UploadVideoMetadata>,
}

impl fmt::Debug for UploadFileBytesInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadFileBytesInput")
            .field("bytes_len", &self.bytes.len())
            .field("file_name", &self.file_name)
            .field("mime_type", &self.mime_type)
            .field("file_type", &self.file_type)
            .field("video_metadata", &self.video_metadata)
            .finish()
    }
}

impl UploadFileBytesInput {
    /// Creates an upload input with an explicit upload type.
    pub fn new(
        bytes: impl Into<Vec<u8>>,
        file_name: impl Into<String>,
        file_type: UploadFileType,
    ) -> Self {
        Self {
            bytes: bytes.into(),
            file_name: file_name.into(),
            mime_type: None,
            file_type,
            video_metadata: None,
        }
    }

    /// Creates a photo upload input.
    pub fn photo(bytes: impl Into<Vec<u8>>, file_name: impl Into<String>) -> Self {
        Self::new(bytes, file_name, UploadFileType::Photo)
    }

    /// Creates a video upload input with video metadata.
    pub fn video(
        bytes: impl Into<Vec<u8>>,
        file_name: impl Into<String>,
        metadata: UploadVideoMetadata,
    ) -> Self {
        Self::new(bytes, file_name, UploadFileType::Video).with_video_metadata(metadata)
    }

    /// Creates a generic document upload input.
    pub fn document(bytes: impl Into<Vec<u8>>, file_name: impl Into<String>) -> Self {
        Self::new(bytes, file_name, UploadFileType::Document)
    }

    /// Sets a MIME type override.
    pub fn with_mime_type(mut self, mime_type: impl Into<String>) -> Self {
        let mime_type = mime_type.into().trim().to_string();
        if !mime_type.is_empty() {
            self.mime_type = Some(mime_type);
        }
        self
    }

    /// Sets video metadata for a video upload.
    pub fn with_video_metadata(mut self, metadata: UploadVideoMetadata) -> Self {
        self.video_metadata = Some(metadata);
        self
    }
}

/// File upload response.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UploadFileResult {
    /// Stable unique file id.
    pub file_unique_id: String,
    /// Uploaded photo id when the file was a photo.
    pub photo_id: Option<i64>,
    /// Uploaded video id when the file was a video.
    pub video_id: Option<i64>,
    /// Uploaded document id when the file was a document.
    pub document_id: Option<i64>,
}

/// Input for marking messages read.
#[must_use]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadMessagesInput {
    /// Peer to mark read.
    pub peer: PeerId,
    /// Highest message id to mark as read.
    pub max_id: Option<i64>,
}

impl ReadMessagesInput {
    /// Creates a read-marker request for a peer.
    pub fn new(peer: PeerId) -> Self {
        Self { peer, max_id: None }
    }

    /// Sets the highest message id to mark as read.
    pub fn with_max_id(mut self, max_id: i64) -> Self {
        self.max_id = Some(max_id);
        self
    }
}

/// Empty response for marking messages read.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ReadMessagesResult {}

/// Peer identifier used by HTTP API helpers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PeerId {
    /// Direct-message peer by user id.
    User(i64),
    /// Chat/thread peer by thread id.
    Thread(i64),
}

impl PeerId {
    /// Creates a direct-message peer id.
    pub fn user(user_id: i64) -> Self {
        Self::User(user_id)
    }

    /// Creates a chat/thread peer id.
    pub fn thread(thread_id: i64) -> Self {
        Self::Thread(thread_id)
    }

    /// Returns the user id when this is a user peer.
    pub fn user_id(self) -> Option<i64> {
        match self {
            Self::User(user_id) => Some(user_id),
            Self::Thread(_) => None,
        }
    }

    /// Returns the thread id when this is a thread peer.
    pub fn thread_id(self) -> Option<i64> {
        match self {
            Self::User(_) => None,
            Self::Thread(thread_id) => Some(thread_id),
        }
    }
}

/// Response from creating or opening a private chat.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CreatePrivateChatResult {
    /// Raw chat object returned by the server.
    pub chat: Value,
    /// Raw dialog object returned by the server.
    pub dialog: Value,
    /// Raw user object returned by the server.
    pub user: Value,
}

/// Input for creating a Linear issue from a message.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateLinearIssueInput {
    /// Source message text.
    pub text: String,
    /// Source message id.
    pub message_id: i64,
    /// Source chat id.
    pub chat_id: i64,
    /// Source sender user id.
    pub from_id: i64,
    /// Source peer.
    pub peer: PeerId,
    /// Optional source space id.
    pub space_id: Option<i64>,
}

impl CreateLinearIssueInput {
    /// Creates input for creating a Linear issue from a message.
    pub fn new(
        text: impl Into<String>,
        message_id: i64,
        chat_id: i64,
        from_id: i64,
        peer: PeerId,
    ) -> Self {
        Self {
            text: text.into(),
            message_id,
            chat_id,
            from_id,
            peer,
            space_id: None,
        }
    }

    /// Sets the optional source space id.
    pub fn with_space_id(mut self, space_id: i64) -> Self {
        self.space_id = Some(space_id);
        self
    }
}

/// Response from creating a Linear issue.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CreateLinearIssueResult {
    /// Created Linear issue URL, if the integration returned one.
    pub link: Option<String>,
}

/// Input for creating a Notion task from a message.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateNotionTaskInput {
    /// Source space id.
    pub space_id: i64,
    /// Source message id.
    pub message_id: i64,
    /// Source chat id.
    pub chat_id: i64,
    /// Source peer.
    pub peer: PeerId,
}

impl CreateNotionTaskInput {
    /// Creates input for creating a Notion task from a message.
    pub fn new(space_id: i64, message_id: i64, chat_id: i64, peer: PeerId) -> Self {
        Self {
            space_id,
            message_id,
            chat_id,
            peer,
        }
    }
}

/// Response from creating a Notion task.
#[derive(Debug, Deserialize, Serialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CreateNotionTaskResult {
    /// Created Notion task URL.
    pub url: String,
    /// Created task title, when returned by the integration.
    pub task_title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged, rename_all = "camelCase")]
enum ApiResponse<T> {
    Ok {
        #[serde(rename = "ok")]
        _ok: bool,
        result: T,
    },
    Err {
        #[serde(rename = "ok")]
        _ok: bool,
        error: String,
        #[serde(rename = "errorCode", alias = "error_code")]
        _error_code: Option<i32>,
        description: Option<String>,
    },
}

fn normalize_api_base_url(base_url: impl Into<String>) -> Result<String, ApiError> {
    let original = base_url.into();
    let normalized = original.trim().trim_end_matches('/').to_string();
    if normalized.is_empty() {
        return Err(ApiError::InvalidBaseUrl {
            url: original,
            message: "base URL cannot be empty".to_string(),
        });
    }

    let parsed = Url::parse(&normalized).map_err(|err| ApiError::InvalidBaseUrl {
        url: normalized.clone(),
        message: err.to_string(),
    })?;

    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(ApiError::InvalidBaseUrl {
            url: normalized,
            message: "scheme must be http or https".to_string(),
        });
    }

    if parsed.host_str().is_none() {
        return Err(ApiError::InvalidBaseUrl {
            url: normalized,
            message: "host is required".to_string(),
        });
    }

    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(ApiError::InvalidBaseUrl {
            url: normalized,
            message: "credentials are not valid in the API base URL".to_string(),
        });
    }

    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(ApiError::InvalidBaseUrl {
            url: normalized,
            message: "query strings and fragments are not valid in the API base URL".to_string(),
        });
    }

    Ok(normalized)
}

fn api_url_path_for_log(url: &str) -> String {
    Url::parse(url)
        .map(|url| url.path().to_string())
        .unwrap_or_else(|_| "<invalid-url>".to_string())
}

fn api_base_url_for_debug(raw_url: &str) -> String {
    Url::parse(raw_url.trim())
        .map(|url| {
            let host = url.host_str().unwrap_or("<missing-host>");
            let port = url
                .port()
                .map(|port| format!(":{port}"))
                .unwrap_or_default();
            let path = url.path().trim_end_matches('/');
            format!("{}://{}{}{}", url.scheme(), host, port, path)
        })
        .unwrap_or_else(|_| "<invalid>".to_string())
}

async fn decode_api_response<T: for<'de> Deserialize<'de>>(
    response: reqwest::Response,
) -> Result<T, ApiError> {
    let status = response.status();
    let text = response.text().await?;
    decode_api_response_text(status, &text)
}

fn decode_api_response_text<T: for<'de> Deserialize<'de>>(
    status: StatusCode,
    text: &str,
) -> Result<T, ApiError> {
    let value: Value = serde_json::from_str(text).map_err(|err| {
        if status.is_success() {
            ApiError::Json(err)
        } else {
            ApiError::Status {
                status: status.as_u16(),
                message: status
                    .canonical_reason()
                    .unwrap_or("HTTP error")
                    .to_string(),
                body: body_preview(text),
            }
        }
    })?;

    if !status.is_success() {
        return Err(
            api_error_from_value(status, &value).unwrap_or_else(|| ApiError::Status {
                status: status.as_u16(),
                message: status
                    .canonical_reason()
                    .unwrap_or("HTTP error")
                    .to_string(),
                body: body_preview(text),
            }),
        );
    }

    if value.get("ok").and_then(Value::as_bool) == Some(false) {
        return Err(
            api_error_from_value(status, &value).unwrap_or_else(|| ApiError::Api {
                status: None,
                error: "API_ERROR".to_string(),
                error_code: None,
                description: "The server returned ok=false without an error description."
                    .to_string(),
            }),
        );
    }

    let api_response: ApiResponse<T> = serde_json::from_value(value)?;
    match api_response {
        ApiResponse::Ok { result, .. } => Ok(result),
        ApiResponse::Err {
            error,
            _error_code,
            description,
            ..
        } => Err(ApiError::Api {
            status: None,
            error,
            error_code: _error_code,
            description: description.unwrap_or_else(|| "Unknown error".to_string()),
        }),
    }
}

fn api_error_from_value(status: StatusCode, value: &Value) -> Option<ApiError> {
    let object = value.as_object()?;
    let error = string_field(value, "error")
        .or_else(|| string_field(value, "code"))
        .or_else(|| string_field(value, "name"))
        .unwrap_or_else(|| {
            if value.get("ok").and_then(Value::as_bool) == Some(false) && status.is_success() {
                return "API_ERROR".to_string();
            }
            status
                .canonical_reason()
                .unwrap_or("HTTP error")
                .to_string()
        });
    let description = string_field(value, "description")
        .or_else(|| string_field(value, "message"))
        .or_else(|| string_field(value, "detail"))
        .unwrap_or_else(|| "No server error description was provided.".to_string());
    let error_code = object
        .get("error_code")
        .or_else(|| object.get("errorCode"))
        .and_then(|value| value.as_i64())
        .and_then(|value| i32::try_from(value).ok());

    Some(ApiError::Api {
        status: Some(status.as_u16()),
        error,
        error_code,
        description,
    })
}

fn string_field(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn body_preview(text: &str) -> Option<String> {
    let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() {
        return None;
    }
    const MAX_BODY_PREVIEW_BYTES: usize = 500;
    if normalized.len() <= MAX_BODY_PREVIEW_BYTES {
        return Some(normalized);
    }

    let mut end = MAX_BODY_PREVIEW_BYTES;
    while !normalized.is_char_boundary(end) {
        end -= 1;
    }
    Some(format!("{}...", &normalized[..end]))
}

fn validate_required_str(field: &'static str, value: &str) -> Result<(), ApiError> {
    if value.trim().is_empty() {
        return Err(ApiError::InvalidInput {
            message: format!("{field} cannot be empty"),
        });
    }
    Ok(())
}

fn validate_bearer_token(token: &str) -> Result<(), ApiError> {
    validate_required_str("bearer token", token)
}

fn validate_auth_metadata(metadata: &AuthMetadata) -> Result<(), ApiError> {
    validate_required_str("device id", metadata.device_id())
}

fn validate_upload_file_input(input: &UploadFileInput) -> Result<(), ApiError> {
    validate_upload_file_metadata(&input.file_name, input.file_type, input.video_metadata)
}

fn validate_upload_file_bytes_input(input: &UploadFileBytesInput) -> Result<(), ApiError> {
    validate_upload_file_metadata(&input.file_name, input.file_type, input.video_metadata)?;
    if input.bytes.is_empty() {
        return Err(ApiError::InvalidInput {
            message: "upload file bytes cannot be empty".to_string(),
        });
    }
    Ok(())
}

fn validate_upload_file_metadata(
    file_name: &str,
    file_type: UploadFileType,
    video_metadata: Option<UploadVideoMetadata>,
) -> Result<(), ApiError> {
    if file_name.trim().is_empty() {
        return Err(ApiError::InvalidInput {
            message: "upload file name cannot be empty".to_string(),
        });
    }

    match (file_type, video_metadata) {
        (UploadFileType::Video, Some(metadata)) => validate_upload_video_metadata(metadata),
        (UploadFileType::Video, None) => Err(ApiError::InvalidInput {
            message: "video uploads require video metadata".to_string(),
        }),
        (_, Some(_)) => Err(ApiError::InvalidInput {
            message: "video metadata can only be used with video uploads".to_string(),
        }),
        (_, None) => Ok(()),
    }
}

fn validate_upload_video_metadata(metadata: UploadVideoMetadata) -> Result<(), ApiError> {
    if metadata.width <= 0 || metadata.height <= 0 || metadata.duration <= 0 {
        return Err(ApiError::InvalidInput {
            message: "video metadata width, height, and duration must be positive".to_string(),
        });
    }
    Ok(())
}

fn validate_positive_id(field: &'static str, value: i64) -> Result<(), ApiError> {
    if value <= 0 {
        return Err(ApiError::InvalidInput {
            message: format!("{field} must be positive"),
        });
    }
    Ok(())
}

fn validate_peer_id(peer: PeerId) -> Result<(), ApiError> {
    match peer {
        PeerId::User(user_id) => validate_positive_id("peer user id", user_id),
        PeerId::Thread(thread_id) => validate_positive_id("peer thread id", thread_id),
    }
}

fn validate_create_linear_issue_input(input: &CreateLinearIssueInput) -> Result<(), ApiError> {
    validate_required_str("Linear issue text", &input.text)?;
    validate_positive_id("message id", input.message_id)?;
    validate_positive_id("chat id", input.chat_id)?;
    validate_positive_id("sender user id", input.from_id)?;
    validate_peer_id(input.peer)?;
    if let Some(space_id) = input.space_id {
        validate_positive_id("space id", space_id)?;
    }
    Ok(())
}

fn validate_create_notion_task_input(input: &CreateNotionTaskInput) -> Result<(), ApiError> {
    validate_positive_id("space id", input.space_id)?;
    validate_positive_id("message id", input.message_id)?;
    validate_positive_id("chat id", input.chat_id)?;
    validate_peer_id(input.peer)
}

fn add_auth_metadata(
    payload: &mut serde_json::Map<String, serde_json::Value>,
    metadata: &AuthMetadata,
) {
    payload.insert("deviceId".to_string(), json!(metadata.device_id()));
    payload.insert(
        "clientType".to_string(),
        json!(auth_session_client_type(metadata.client())),
    );
    payload.insert(
        "clientVersion".to_string(),
        json!(metadata.client().client_version()),
    );
    if let Some(device_name) = metadata.device_name() {
        payload.insert("deviceName".to_string(), json!(device_name));
    }
}

fn auth_session_client_type(identity: &ClientIdentity) -> &str {
    match identity.client_type() {
        // Keep this to server session client types. Custom SDK,
        // bridge, and agent identities still travel in headers/user agents.
        "ios" | "macos" | "web" | "api" | "android" | "windows" | "linux" | "cli" => {
            identity.client_type()
        }
        _ => DEFAULT_AUTH_SESSION_CLIENT_TYPE,
    }
}

fn add_peer_selector_fields(
    payload: &mut serde_json::Map<String, serde_json::Value>,
    peer: PeerId,
) {
    match peer {
        PeerId::User(user_id) => {
            payload.insert("peerUserId".to_string(), json!(user_id));
        }
        PeerId::Thread(thread_id) => {
            payload.insert("peerThreadId".to_string(), json!(thread_id));
        }
    }
}

fn peer_id_object(peer: PeerId) -> serde_json::Map<String, serde_json::Value> {
    let mut peer_id = serde_json::Map::new();
    match peer {
        PeerId::User(user_id) => {
            peer_id.insert("userId".to_string(), json!(user_id));
        }
        PeerId::Thread(thread_id) => {
            peer_id.insert("threadId".to_string(), json!(thread_id));
        }
    }
    peer_id
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::future::Future;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[derive(Debug, Deserialize, PartialEq)]
    #[serde(rename_all = "camelCase")]
    struct TestResult {
        value: String,
    }

    #[derive(Debug)]
    struct CapturedRequest {
        method: String,
        path: String,
        headers: BTreeMap<String, String>,
        body: Value,
    }

    #[test]
    fn api_client_builder_normalizes_base_url() {
        let client = ApiClient::try_new(" https://api.inline.chat/v1/ ").unwrap();
        assert_eq!(client.base_url(), "https://api.inline.chat/v1");
    }

    #[test]
    fn api_client_builder_uses_default_request_timeout() {
        let client = ApiClient::try_new("https://api.inline.chat/v1").unwrap();
        assert_eq!(client.request_timeout(), Some(DEFAULT_API_TIMEOUT));
    }

    #[test]
    fn api_client_builder_can_override_or_disable_request_timeout() {
        let client = ApiClient::builder("https://api.inline.chat/v1")
            .request_timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        assert_eq!(client.request_timeout(), Some(Duration::from_secs(5)));

        let client = ApiClient::builder("https://api.inline.chat/v1")
            .without_request_timeout()
            .build()
            .unwrap();
        assert_eq!(client.request_timeout(), None);
    }

    #[test]
    fn custom_http_clients_own_their_timeout_policy() {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap();
        let client = ApiClient::try_with_http_client("https://api.inline.chat/v1", http).unwrap();
        assert_eq!(client.request_timeout(), None);

        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap();
        let client = ApiClient::builder("https://api.inline.chat/v1")
            .request_timeout(Duration::from_secs(5))
            .http_client(http)
            .build()
            .unwrap();
        assert_eq!(client.request_timeout(), None);
    }

    #[test]
    fn api_client_builder_rejects_invalid_base_url() {
        let err = match ApiClient::try_new("inline.test") {
            Ok(_) => panic!("expected invalid base URL"),
            Err(err) => err,
        };
        match err {
            ApiError::InvalidBaseUrl { url, message } => {
                assert_eq!(url, "inline.test");
                assert!(message.contains("relative URL without a base"));
            }
            other => panic!("expected invalid base URL, got {other:?}"),
        }

        let err = match ApiClient::try_new("wss://api.inline.chat/v1") {
            Ok(_) => panic!("expected invalid base URL"),
            Err(err) => err,
        };
        match err {
            ApiError::InvalidBaseUrl { message, .. } => {
                assert_eq!(message, "scheme must be http or https");
            }
            other => panic!("expected invalid base URL, got {other:?}"),
        }

        let err = match ApiClient::try_new("https://user:secret@api.inline.chat/v1") {
            Ok(_) => panic!("expected invalid base URL"),
            Err(err) => err,
        };
        match &err {
            ApiError::InvalidBaseUrl { message, .. } => {
                assert_eq!(message, "credentials are not valid in the API base URL");
                assert!(!err.to_string().contains("secret"));
            }
            other => panic!("expected invalid base URL, got {other:?}"),
        }

        let err = match ApiClient::try_new("https://api.inline.chat/v1?debug=true") {
            Ok(_) => panic!("expected invalid base URL"),
            Err(err) => err,
        };
        match err {
            ApiError::InvalidBaseUrl { message, .. } => {
                assert_eq!(
                    message,
                    "query strings and fragments are not valid in the API base URL"
                );
            }
            other => panic!("expected invalid base URL, got {other:?}"),
        }
    }

    #[test]
    fn api_debug_output_redacts_unsafe_url_parts() {
        let raw_url = "https://user:url-secret@api.inline.chat/v1?token=query-secret#frag";
        let builder = ApiClient::builder(raw_url);
        let builder_debug = format!("{builder:?}");

        assert!(builder_debug.contains("https://api.inline.chat/v1"));
        assert!(!builder_debug.contains("url-secret"));
        assert!(!builder_debug.contains("query-secret"));

        let err = ApiClient::try_new(raw_url).unwrap_err();
        let err_debug = format!("{err:?}");

        assert!(err_debug.contains("https://api.inline.chat/v1"));
        assert!(!err_debug.contains("url-secret"));
        assert!(!err_debug.contains("query-secret"));
    }

    #[test]
    fn api_url_path_for_log_omits_origin_query_and_fragment() {
        assert_eq!(
            api_url_path_for_log("https://api.inline.chat/v1/getMe?token=secret#frag"),
            "/v1/getMe"
        );
    }

    #[tokio::test]
    async fn send_email_code_posts_json_body_with_auth_metadata() {
        let request = capture_json_request(
            r#"{"ok":true,"result":{"existingUser":true,"needsInviteCode":false,"challengeToken":"challenge-1"}}"#,
            |client| async move {
                client
                    .send_email_code(
                        "amy@example.com",
                        &AuthMetadata::new(
                            "device-1",
                            ClientIdentity::new("bridge-agent", "1.0.0"),
                        )
                        .with_device_name("umbrel"),
                    )
                    .await
            },
        )
        .await;

        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/v1/sendEmailCode");
        assert!(
            request
                .headers
                .get("content-type")
                .is_some_and(|header| header.starts_with("application/json"))
        );
        assert_eq!(request.body.get("email"), Some(&json!("amy@example.com")));
        assert_eq!(request.body.get("deviceId"), Some(&json!("device-1")));
        assert_eq!(request.body.get("deviceName"), Some(&json!("umbrel")));
        assert_eq!(request.body.get("clientType"), Some(&json!("api")));
        assert_eq!(request.body.get("clientVersion"), Some(&json!("1.0.0")));
    }

    #[tokio::test]
    async fn read_messages_posts_bearer_json_body() {
        let request = capture_json_request(r#"{"ok":true,"result":{}}"#, |client| async move {
            client
                .read_messages(
                    "secret-token",
                    ReadMessagesInput::new(PeerId::user(42)).with_max_id(99),
                )
                .await
        })
        .await;

        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/v1/readMessages");
        assert_eq!(
            request.headers.get("authorization").map(String::as_str),
            Some("Bearer secret-token")
        );
        assert!(
            request
                .headers
                .get("content-type")
                .is_some_and(|header| header.starts_with("application/json"))
        );
        assert_eq!(request.body.get("peerUserId"), Some(&json!(42)));
        assert_eq!(request.body.get("maxId"), Some(&json!(99)));
        assert!(request.body.get("peerThreadId").is_none());
    }

    #[tokio::test]
    async fn logout_posts_empty_bearer_request() {
        let request = capture_json_request(r#"{"ok":true,"result":null}"#, |client| async move {
            client.logout("secret-token").await
        })
        .await;

        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/v1/logout");
        assert_eq!(
            request.headers.get("authorization").map(String::as_str),
            Some("Bearer secret-token")
        );
        assert_eq!(request.body, json!({}));
    }

    #[test]
    fn upload_file_type_parses_and_displays_wire_values() {
        assert_eq!(
            "photo".parse::<UploadFileType>().unwrap(),
            UploadFileType::Photo
        );
        assert_eq!(
            "VIDEO".parse::<UploadFileType>().unwrap(),
            UploadFileType::Video
        );
        assert_eq!(UploadFileType::Document.to_string(), "document");

        let err = "avatar".parse::<UploadFileType>().unwrap_err();
        assert_eq!(err.value, "avatar");
    }

    #[test]
    fn upload_file_type_serializes_as_wire_values() {
        assert_eq!(
            serde_json::to_string(&UploadFileType::Photo).unwrap(),
            r#""photo""#
        );
        assert_eq!(
            serde_json::from_str::<UploadFileType>(r#""video""#).unwrap(),
            UploadFileType::Video
        );
    }

    #[test]
    fn upload_input_constructors_set_expected_fields() {
        let metadata = UploadVideoMetadata::new(1920, 1080, 12);
        let video =
            UploadFileInput::video("clip.mp4", "clip.mp4", metadata).with_mime_type(" video/mp4 ");

        assert_eq!(video.path, PathBuf::from("clip.mp4"));
        assert_eq!(video.file_name, "clip.mp4");
        assert_eq!(video.file_type, UploadFileType::Video);
        assert_eq!(video.mime_type.as_deref(), Some("video/mp4"));
        assert_eq!(video.video_metadata, Some(metadata));

        let document = UploadFileInput::document("notes.txt", "notes.txt").with_mime_type(" ");
        assert_eq!(document.file_type, UploadFileType::Document);
        assert!(document.mime_type.is_none());
        assert!(document.video_metadata.is_none());
    }

    #[test]
    fn upload_bytes_input_constructors_set_expected_fields() {
        let metadata = UploadVideoMetadata::new(1920, 1080, 12);
        let video = UploadFileBytesInput::video(vec![1, 2, 3], "clip.mp4", metadata)
            .with_mime_type(" video/mp4 ");

        assert_eq!(video.bytes, vec![1, 2, 3]);
        assert_eq!(video.file_name, "clip.mp4");
        assert_eq!(video.file_type, UploadFileType::Video);
        assert_eq!(video.mime_type.as_deref(), Some("video/mp4"));
        assert_eq!(video.video_metadata, Some(metadata));

        let document = UploadFileBytesInput::document(vec![1], "notes.txt").with_mime_type(" ");
        assert_eq!(document.file_type, UploadFileType::Document);
        assert!(document.mime_type.is_none());
        assert!(document.video_metadata.is_none());
    }

    #[test]
    fn upload_input_debug_redacts_local_path() {
        let input = UploadFileInput::document("/home/alice/private/report.pdf", "report.pdf")
            .with_mime_type("application/pdf");
        let debug = format!("{input:?}");

        assert!(debug.contains("report.pdf"));
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("/home/alice/private"));
    }

    #[test]
    fn upload_bytes_input_debug_redacts_contents() {
        let input = UploadFileBytesInput::document(vec![115, 101, 99, 114, 101, 116], "report.pdf")
            .with_mime_type("application/pdf");
        let debug = format!("{input:?}");

        assert!(debug.contains("report.pdf"));
        assert!(debug.contains("bytes_len"));
        assert!(!debug.contains("secret"));
    }

    #[test]
    fn upload_input_validation_rejects_invalid_video_metadata_shape() {
        let missing_metadata = UploadFileInput::new("clip.mp4", "clip.mp4", UploadFileType::Video);
        match validate_upload_file_input(&missing_metadata).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "video uploads require video metadata");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        let document_with_video = UploadFileInput::document("notes.txt", "notes.txt")
            .with_video_metadata(UploadVideoMetadata::new(1, 1, 1));
        match validate_upload_file_input(&document_with_video).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(
                    message,
                    "video metadata can only be used with video uploads"
                );
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        let bad_dimensions = UploadFileInput::video(
            "clip.mp4",
            "clip.mp4",
            UploadVideoMetadata::new(0, 1080, 12),
        );
        match validate_upload_file_input(&bad_dimensions).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(
                    message,
                    "video metadata width, height, and duration must be positive"
                );
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn upload_input_validation_rejects_empty_file_name() {
        let input = UploadFileInput::document("notes.txt", " ");
        match validate_upload_file_input(&input).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "upload file name cannot be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn upload_bytes_input_validation_rejects_empty_bytes() {
        let input = UploadFileBytesInput::document(Vec::new(), "notes.txt");
        match validate_upload_file_bytes_input(&input).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "upload file bytes cannot be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn auth_and_token_validation_reject_blank_required_fields() {
        match validate_required_str("email", "  ").unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "email cannot be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        match validate_bearer_token("").unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "bearer token cannot be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        match validate_auth_metadata(&AuthMetadata::sdk(" ")).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "device id cannot be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn auth_result_debug_redacts_tokens() {
        let send_code = SendCodeResult {
            existing_user: true,
            needs_invite_code: false,
            challenge_token: Some("challenge-secret".to_string()),
        };
        let verify_code = VerifyCodeResult {
            user_id: 42,
            token: "bearer-secret".to_string(),
        };

        let send_debug = format!("{send_code:?}");
        let verify_debug = format!("{verify_code:?}");

        assert!(send_debug.contains("<redacted>"));
        assert!(!send_debug.contains("challenge-secret"));
        assert!(verify_debug.contains("<redacted>"));
        assert!(!verify_debug.contains("bearer-secret"));
    }

    #[test]
    fn api_input_validation_rejects_non_positive_ids() {
        match validate_peer_id(PeerId::thread(0)).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "peer thread id must be positive");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        let linear = CreateLinearIssueInput::new("ship it", 0, 20, 30, PeerId::thread(20));
        match validate_create_linear_issue_input(&linear).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "message id must be positive");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }

        let notion = CreateNotionTaskInput::new(1, 2, 0, PeerId::thread(3));
        match validate_create_notion_task_input(&notion).unwrap_err() {
            ApiError::InvalidInput { message } => {
                assert_eq!(message, "chat id must be positive");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn peer_id_helpers_encode_user_and_thread_peers() {
        assert_eq!(PeerId::user(42).user_id(), Some(42));
        assert_eq!(PeerId::user(42).thread_id(), None);
        assert_eq!(PeerId::thread(99).thread_id(), Some(99));
        assert_eq!(PeerId::thread(99).user_id(), None);

        let mut payload = serde_json::Map::new();
        add_peer_selector_fields(&mut payload, PeerId::user(42));
        assert_eq!(payload.get("peerUserId"), Some(&json!(42)));
        assert!(payload.get("peerThreadId").is_none());

        let peer_id = peer_id_object(PeerId::thread(99));
        assert_eq!(peer_id.get("threadId"), Some(&json!(99)));
        assert!(peer_id.get("userId").is_none());
    }

    #[test]
    fn api_input_constructors_keep_required_fields_explicit() {
        let read = ReadMessagesInput::new(PeerId::user(42)).with_max_id(99);
        assert_eq!(read.peer, PeerId::user(42));
        assert_eq!(read.max_id, Some(99));

        let linear = CreateLinearIssueInput::new("ship it", 10, 20, 30, PeerId::thread(20))
            .with_space_id(40);
        assert_eq!(linear.text, "ship it");
        assert_eq!(linear.message_id, 10);
        assert_eq!(linear.chat_id, 20);
        assert_eq!(linear.from_id, 30);
        assert_eq!(linear.peer, PeerId::thread(20));
        assert_eq!(linear.space_id, Some(40));

        let notion = CreateNotionTaskInput::new(1, 2, 3, PeerId::thread(3));
        assert_eq!(notion.space_id, 1);
        assert_eq!(notion.message_id, 2);
        assert_eq!(notion.chat_id, 3);
        assert_eq!(notion.peer, PeerId::thread(3));
    }

    #[test]
    fn decodes_success_envelope() {
        let result: TestResult =
            decode_api_response_text(StatusCode::OK, r#"{"ok":true,"result":{"value":"done"}}"#)
                .unwrap();

        assert_eq!(
            result,
            TestResult {
                value: "done".to_string()
            }
        );
    }

    #[test]
    fn preserves_json_api_error_fields() {
        let err = decode_api_response_text::<TestResult>(
            StatusCode::BAD_REQUEST,
            r#"{"ok":false,"error":"INVALID_CODE","error_code":123,"description":"Code is invalid"}"#,
        )
        .unwrap_err();

        match err {
            ApiError::Api {
                status,
                error,
                error_code,
                description,
            } => {
                assert_eq!(status, Some(400));
                assert_eq!(error, "INVALID_CODE");
                assert_eq!(error_code, Some(123));
                assert_eq!(description, "Code is invalid");
            }
            other => panic!("expected api error, got {other:?}"),
        }
    }

    #[test]
    fn preserves_nonstandard_ok_false_message() {
        let err = decode_api_response_text::<TestResult>(
            StatusCode::OK,
            r#"{"ok":false,"message":"Not enough permissions"}"#,
        )
        .unwrap_err();

        match err {
            ApiError::Api {
                status,
                error,
                error_code,
                description,
            } => {
                assert_eq!(status, Some(200));
                assert_eq!(error, "API_ERROR");
                assert_eq!(error_code, None);
                assert_eq!(description, "Not enough permissions");
            }
            other => panic!("expected api error, got {other:?}"),
        }
    }

    #[test]
    fn preserves_non_json_http_body_preview() {
        let err = decode_api_response_text::<TestResult>(
            StatusCode::INTERNAL_SERVER_ERROR,
            "upstream failed\nwith details",
        )
        .unwrap_err();

        match err {
            ApiError::Status {
                status,
                message,
                body,
            } => {
                assert_eq!(status, 500);
                assert_eq!(message, "Internal Server Error");
                assert_eq!(body.as_deref(), Some("upstream failed with details"));
            }
            other => panic!("expected status error, got {other:?}"),
        }
    }

    #[test]
    fn auth_metadata_includes_client_identity() {
        let mut payload = serde_json::Map::new();
        let identity = ClientIdentity::new("cli", "1.2.3");
        add_auth_metadata(
            &mut payload,
            &AuthMetadata::new("device-1", identity).with_device_name("mo-mac"),
        );

        assert_eq!(payload.get("deviceId"), Some(&json!("device-1")));
        assert_eq!(payload.get("clientType"), Some(&json!("cli")));
        assert_eq!(payload.get("clientVersion"), Some(&json!("1.2.3")));
        assert_eq!(payload.get("deviceName"), Some(&json!("mo-mac")));
    }

    #[test]
    fn auth_metadata_maps_non_session_client_identity_to_api() {
        let mut payload = serde_json::Map::new();
        add_auth_metadata(
            &mut payload,
            &AuthMetadata::new("device-1", ClientIdentity::new("my-agent", "0.1.0")),
        );

        assert_eq!(payload.get("deviceId"), Some(&json!("device-1")));
        assert_eq!(payload.get("clientType"), Some(&json!("api")));
        assert_eq!(payload.get("clientVersion"), Some(&json!("0.1.0")));
        assert!(payload.get("deviceName").is_none());
    }

    #[test]
    fn auth_metadata_preserves_known_session_client_identity() {
        let mut payload = serde_json::Map::new();
        add_auth_metadata(
            &mut payload,
            &AuthMetadata::new("device-1", ClientIdentity::new("web", "0.1.0")),
        );

        assert_eq!(payload.get("clientType"), Some(&json!("web")));
    }

    async fn capture_json_request<F, Fut, T>(
        response_body: &'static str,
        exercise: F,
    ) -> CapturedRequest
    where
        F: FnOnce(ApiClient) -> Fut,
        Fut: Future<Output = Result<T, ApiError>>,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut chunk = [0_u8; 1024];
                let read = stream.read(&mut chunk).await.unwrap();
                assert!(read != 0, "client closed before completing request");
                request.extend_from_slice(&chunk[..read]);
                if let Some(header_end) = http_header_end(&request) {
                    let header_text = String::from_utf8_lossy(&request[..header_end]);
                    let content_length = http_content_length(&header_text);
                    if request.len() >= header_end + content_length {
                        break;
                    }
                }
            }

            let captured = parse_captured_request(&request);
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            captured
        });

        let client = ApiClient::try_new(format!("http://{addr}/v1")).unwrap();
        exercise(client).await.unwrap();
        server.await.unwrap()
    }

    fn http_header_end(request: &[u8]) -> Option<usize> {
        request
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|position| position + 4)
    }

    fn http_content_length(headers: &str) -> usize {
        headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .unwrap_or(0)
    }

    fn parse_captured_request(request: &[u8]) -> CapturedRequest {
        let header_end = http_header_end(request).unwrap();
        let headers = String::from_utf8_lossy(&request[..header_end]);
        let mut lines = headers.lines();
        let request_line = lines.next().unwrap();
        let mut request_parts = request_line.split_whitespace();
        let method = request_parts.next().unwrap().to_owned();
        let path = request_parts.next().unwrap().to_owned();
        let headers = lines
            .filter_map(|line| {
                let (name, value) = line.split_once(':')?;
                Some((name.to_ascii_lowercase(), value.trim().to_owned()))
            })
            .collect::<BTreeMap<_, _>>();
        let body = serde_json::from_slice(&request[header_end..]).unwrap();

        CapturedRequest {
            method,
            path,
            headers,
            body,
        }
    }
}
