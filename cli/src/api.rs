use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("unexpected status: {0}")]
    Status(u16),
    #[error("api error: {error} ({description})")]
    Api { error: String, description: String },
}

#[derive(Clone)]
pub struct ApiClient {
    base_url: String,
    http: Client,
}

impl ApiClient {
    pub fn new(base_url: String) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            http: Client::new(),
        }
    }

    pub async fn send_email_code(&self, email: &str) -> Result<SendCodeResult, ApiError> {
        let url = format!("{}/sendEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        self.post(url, payload).await
    }

    pub async fn verify_email_code(
        &self,
        email: &str,
        code: &str,
        client_type: &str,
        client_version: &str,
        device_name: Option<&str>,
    ) -> Result<VerifyCodeResult, ApiError> {
        let url = format!("{}/verifyEmailCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("email".to_string(), json!(email));
        payload.insert("code".to_string(), json!(code));
        payload.insert("clientType".to_string(), json!(client_type));
        payload.insert("clientVersion".to_string(), json!(client_version));
        if let Some(device_name) = device_name {
            payload.insert("deviceName".to_string(), json!(device_name));
        }
        self.post(url, payload).await
    }

    pub async fn send_sms_code(&self, phone_number: &str) -> Result<SendCodeResult, ApiError> {
        let url = format!("{}/sendSmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        self.post(url, payload).await
    }

    pub async fn verify_sms_code(
        &self,
        phone_number: &str,
        code: &str,
        client_type: &str,
        client_version: &str,
        device_name: Option<&str>,
    ) -> Result<VerifyCodeResult, ApiError> {
        let url = format!("{}/verifySmsCode", self.base_url);
        let mut payload = serde_json::Map::new();
        payload.insert("phoneNumber".to_string(), json!(phone_number));
        payload.insert("code".to_string(), json!(code));
        payload.insert("clientType".to_string(), json!(client_type));
        payload.insert("clientVersion".to_string(), json!(client_version));
        if let Some(device_name) = device_name {
            payload.insert("deviceName".to_string(), json!(device_name));
        }
        self.post(url, payload).await
    }

    pub async fn upload_file(&self, token: &str, input: UploadFileInput) -> Result<UploadFileResult, ApiError> {
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
        let status = response.status();
        if !status.is_success() {
            return Err(ApiError::Status(status.as_u16()));
        }
        let api_response: ApiResponse<UploadFileResult> = response.json().await?;
        match api_response {
            ApiResponse::Ok { result, .. } => Ok(result),
            ApiResponse::Err {
                error,
                description,
                ..
            } => Err(ApiError::Api {
                error,
                description: description.unwrap_or_else(|| "Unknown error".to_string()),
            }),
        }
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
        let status = response.status();
        if !status.is_success() {
            return Err(ApiError::Status(status.as_u16()));
        }
        let api_response: ApiResponse<T> = response.json().await?;
        match api_response {
            ApiResponse::Ok { result, .. } => Ok(result),
            ApiResponse::Err {
                error,
                description,
                ..
            } => Err(ApiError::Api {
                error,
                description: description.unwrap_or_else(|| "Unknown error".to_string()),
            }),
        }
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
        let status = response.status();
        if !status.is_success() {
            return Err(ApiError::Status(status.as_u16()));
        }
        let api_response: ApiResponse<T> = response.json().await?;
        match api_response {
            ApiResponse::Ok { result, .. } => Ok(result),
            ApiResponse::Err {
                error,
                description,
                ..
            } => Err(ApiError::Api {
                error,
                description: description.unwrap_or_else(|| "Unknown error".to_string()),
            }),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendCodeResult {
    pub existing_user: bool,
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
    Ok { ok: bool, result: T },
    Err {
        ok: bool,
        error: String,
        error_code: Option<i32>,
        description: Option<String>,
    },
}
