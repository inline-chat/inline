use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use thiserror::Error;

use crate::client_info::{self, AuthMetadata, ClientIdentity};

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("api request failed with HTTP {status}: {message}")]
    Status {
        status: u16,
        message: String,
        body: Option<String>,
    },
    #[error("api error: {error}: {description}")]
    Api {
        status: Option<u16>,
        error: String,
        error_code: Option<i32>,
        description: String,
    },
}

#[derive(Clone)]
pub struct ApiClient {
    base_url: String,
    http: Client,
}

impl ApiClient {
    pub fn new(base_url: String) -> Self {
        Self::new_with_identity(base_url, ClientIdentity::cli())
    }

    pub fn new_with_identity(base_url: String, identity: ClientIdentity<'_>) -> Self {
        let http = client_info::http_client_builder_for(identity)
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            http,
        }
    }

    pub async fn send_email_code(
        &self,
        email: &str,
        metadata: AuthMetadata<'_>,
    ) -> Result<SendCodeResult, ApiError> {
        let url = format!("{}/sendEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    pub async fn verify_email_code(
        &self,
        email: &str,
        code: &str,
        challenge_token: Option<&str>,
        metadata: AuthMetadata<'_>,
    ) -> Result<VerifyCodeResult, ApiError> {
        let url = format!("{}/verifyEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        payload.insert("code".to_string(), json!(code));
        if let Some(challenge_token) = challenge_token {
            if !challenge_token.trim().is_empty() {
                payload.insert("challengeToken".to_string(), json!(challenge_token));
            }
        }
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    pub async fn send_sms_code(
        &self,
        phone_number: &str,
        metadata: AuthMetadata<'_>,
    ) -> Result<SendCodeResult, ApiError> {
        let url = format!("{}/sendSmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    pub async fn verify_sms_code(
        &self,
        phone_number: &str,
        code: &str,
        metadata: AuthMetadata<'_>,
    ) -> Result<VerifyCodeResult, ApiError> {
        let url = format!("{}/verifySmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        payload.insert("code".to_string(), json!(code));
        add_auth_metadata(&mut payload, metadata);
        self.post(url, payload).await
    }

    pub async fn upload_file(
        &self,
        token: &str,
        input: UploadFileInput,
    ) -> Result<UploadFileResult, ApiError> {
        let url = format!("{}/uploadFile", self.base_url);
        let mut form = reqwest::multipart::Form::new().text("type", input.file_type.as_str());
        let bytes = fs::read(&input.path)?;
        let mut file_part = reqwest::multipart::Part::bytes(bytes);
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
        decode_api_response(response).await
    }

    pub async fn read_messages(
        &self,
        token: &str,
        input: ReadMessagesInput,
    ) -> Result<ReadMessagesResult, ApiError> {
        let url = format!("{}/readMessages", self.base_url);
        let mut payload = serde_json::Map::new();
        if let Some(peer_user_id) = input.peer_user_id {
            payload.insert("peerUserId".to_string(), json!(peer_user_id));
        }
        if let Some(peer_thread_id) = input.peer_thread_id {
            payload.insert("peerThreadId".to_string(), json!(peer_thread_id));
        }
        if let Some(max_id) = input.max_id {
            payload.insert("maxId".to_string(), json!(max_id));
        }
        self.post_with_token(url, token, payload).await
    }

    pub async fn create_private_chat(
        &self,
        token: &str,
        user_id: i64,
    ) -> Result<CreatePrivateChatResult, ApiError> {
        let url = format!("{}/createPrivateChat", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("userId".to_string(), json!(user_id));
        self.post_with_token(url, token, payload).await
    }

    pub async fn create_linear_issue(
        &self,
        token: &str,
        input: CreateLinearIssueInput,
    ) -> Result<CreateLinearIssueResult, ApiError> {
        let url = format!("{}/createLinearIssue", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("text".to_string(), json!(input.text));
        payload.insert("messageId".to_string(), json!(input.message_id));
        payload.insert("chatId".to_string(), json!(input.chat_id));
        payload.insert("fromId".to_string(), json!(input.from_id));

        let mut peer_id = serde_json::Map::new();
        if let Some(user_id) = input.peer_user_id {
            peer_id.insert("userId".to_string(), json!(user_id));
        } else if let Some(thread_id) = input.peer_thread_id {
            peer_id.insert("threadId".to_string(), json!(thread_id));
        }
        payload.insert("peerId".to_string(), json!(peer_id));

        if let Some(space_id) = input.space_id {
            payload.insert("spaceId".to_string(), json!(space_id));
        }

        self.post_with_token(url, token, payload).await
    }

    pub async fn create_notion_task(
        &self,
        token: &str,
        input: CreateNotionTaskInput,
    ) -> Result<CreateNotionTaskResult, ApiError> {
        let url = format!("{}/createNotionTask", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("spaceId".to_string(), json!(input.space_id));
        payload.insert("messageId".to_string(), json!(input.message_id));
        payload.insert("chatId".to_string(), json!(input.chat_id));

        let mut peer_id = serde_json::Map::new();
        if let Some(user_id) = input.peer_user_id {
            peer_id.insert("userId".to_string(), json!(user_id));
        } else if let Some(thread_id) = input.peer_thread_id {
            peer_id.insert("threadId".to_string(), json!(thread_id));
        }
        payload.insert("peerId".to_string(), json!(peer_id));

        self.post_with_token(url, token, payload).await
    }

    async fn post<T: for<'de> Deserialize<'de>>(
        &self,
        url: String,
        payload: serde_json::Map<String, serde_json::Value>,
    ) -> Result<T, ApiError> {
        let response = self.http.post(url).json(&payload).send().await?;
        decode_api_response(response).await
    }

    async fn post_with_token<T: for<'de> Deserialize<'de>>(
        &self,
        url: String,
        token: &str,
        payload: serde_json::Map<String, serde_json::Value>,
    ) -> Result<T, ApiError> {
        let response = self
            .http
            .post(url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await?;
        decode_api_response(response).await
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendCodeResult {
    #[allow(dead_code)]
    pub existing_user: bool,
    #[allow(dead_code)]
    pub needs_invite_code: bool,
    pub challenge_token: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyCodeResult {
    pub user_id: i64,
    pub token: String,
}

#[derive(Debug, Clone)]
pub enum UploadFileType {
    Photo,
    Video,
    Document,
}

impl UploadFileType {
    pub fn as_str(&self) -> &'static str {
        match self {
            UploadFileType::Photo => "photo",
            UploadFileType::Video => "video",
            UploadFileType::Document => "document",
        }
    }
}

#[derive(Debug, Clone)]
pub struct UploadVideoMetadata {
    pub width: i32,
    pub height: i32,
    pub duration: i32,
}

#[derive(Debug, Clone)]
pub struct UploadFileInput {
    pub path: PathBuf,
    pub file_name: String,
    pub mime_type: Option<String>,
    pub file_type: UploadFileType,
    pub video_metadata: Option<UploadVideoMetadata>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UploadFileResult {
    pub file_unique_id: String,
    pub photo_id: Option<i64>,
    pub video_id: Option<i64>,
    pub document_id: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct ReadMessagesInput {
    pub peer_user_id: Option<i64>,
    pub peer_thread_id: Option<i64>,
    pub max_id: Option<i64>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ReadMessagesResult {}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CreatePrivateChatResult {
    pub chat: Value,
    pub dialog: Value,
    pub user: Value,
}

#[derive(Debug, Clone)]
pub struct CreateLinearIssueInput {
    pub text: String,
    pub message_id: i64,
    pub chat_id: i64,
    pub from_id: i64,
    pub peer_user_id: Option<i64>,
    pub peer_thread_id: Option<i64>,
    pub space_id: Option<i64>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CreateLinearIssueResult {
    pub link: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CreateNotionTaskInput {
    pub space_id: i64,
    pub message_id: i64,
    pub chat_id: i64,
    pub peer_user_id: Option<i64>,
    pub peer_thread_id: Option<i64>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CreateNotionTaskResult {
    pub url: String,
    pub task_title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged, rename_all = "camelCase")]
enum ApiResponse<T> {
    Ok {
        #[allow(dead_code)]
        ok: bool,
        result: T,
    },
    Err {
        #[allow(dead_code)]
        ok: bool,
        error: String,
        #[allow(dead_code)]
        error_code: Option<i32>,
        description: Option<String>,
    },
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
            error_code,
            description,
            ..
        } => Err(ApiError::Api {
            status: None,
            error,
            error_code,
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

fn add_auth_metadata(
    payload: &mut serde_json::Map<String, serde_json::Value>,
    metadata: AuthMetadata<'_>,
) {
    payload.insert("deviceId".to_string(), json!(metadata.device_id));
    payload.insert("clientType".to_string(), json!(metadata.client.client_type));
    payload.insert(
        "clientVersion".to_string(),
        json!(metadata.client.client_version),
    );
    if let Some(device_name) = metadata.device_name {
        payload.insert("deviceName".to_string(), json!(device_name));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize, PartialEq)]
    #[serde(rename_all = "camelCase")]
    struct TestResult {
        value: String,
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
        add_auth_metadata(&mut payload, AuthMetadata::cli("device-1", Some("mo-mac")));

        assert_eq!(payload.get("deviceId"), Some(&json!("device-1")));
        assert_eq!(payload.get("clientType"), Some(&json!("cli")));
        assert_eq!(
            payload.get("clientVersion"),
            Some(&json!(client_info::client_version()))
        );
        assert_eq!(payload.get("deviceName"), Some(&json!("mo-mac")));
    }

    #[test]
    fn auth_metadata_accepts_non_cli_client_identity() {
        let mut payload = serde_json::Map::new();
        add_auth_metadata(
            &mut payload,
            AuthMetadata::new(
                "device-1",
                None,
                client_info::ClientIdentity::new("my-agent", "0.1.0"),
            ),
        );

        assert_eq!(payload.get("deviceId"), Some(&json!("device-1")));
        assert_eq!(payload.get("clientType"), Some(&json!("my-agent")));
        assert_eq!(payload.get("clientVersion"), Some(&json!("0.1.0")));
        assert!(payload.get("deviceName").is_none());
    }
}
