//! A small client for the OpenCode service HTTP API.
//!
//! Requests and responses stay `serde_json::Value` at this layer: OpenCode's
//! API is generated from an evolving Effect schema, and the driver reads the
//! fields it needs leniently so additive server changes never break a turn.
//! Declared errors carry an Effect `_tag` (`SessionBusyError`,
//! `ConflictError`, ...) that callers classify.

use std::time::Duration;

use futures_util::{Stream, StreamExt};
use reqwest::Method;
use serde_json::Value;

use crate::service::Endpoint;
use crate::sse::SseDecoder;

/// Default timeout for one request.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A typed failure of one request.
#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum ApiError {
    /// The request may not have reached the service (connect, timeout, reset).
    #[error("OpenCode is not reachable: {0}")]
    Transport(String),
    /// The service answered with an error status.
    #[error("{message}")]
    Status {
        /// HTTP status.
        status: u16,
        /// Effect error tag, when declared.
        tag: Option<String>,
        /// Server message.
        message: String,
    },
    /// The service answered something this driver cannot read.
    #[error("OpenCode returned an unexpected response: {0}")]
    Decode(String),
}

impl ApiError {
    /// The status code, when the service answered.
    pub fn status(&self) -> Option<u16> {
        match self {
            Self::Status { status, .. } => Some(*status),
            _ => None,
        }
    }

    /// The declared error tag.
    pub fn tag(&self) -> Option<&str> {
        match self {
            Self::Status { tag, .. } => tag.as_deref(),
            _ => None,
        }
    }

    pub fn is_not_found(&self) -> bool {
        self.status() == Some(404)
    }

    pub fn is_conflict(&self) -> bool {
        self.status() == Some(409)
    }

    /// The session is running and the request needed it idle.
    pub fn is_busy(&self) -> bool {
        self.tag() == Some("SessionBusyError")
    }

    /// Whether the service may have applied a mutation despite the error.
    pub fn outcome_unknown(&self) -> bool {
        match self {
            Self::Transport(_) => true,
            Self::Status { status, .. } => *status >= 500,
            Self::Decode(_) => true,
        }
    }
}

/// One service connection.
#[derive(Clone)]
pub struct Api {
    endpoint: Endpoint,
    http: reqwest::Client,
    streaming: reqwest::Client,
}

impl std::fmt::Debug for Api {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Api")
            .field("endpoint", &self.endpoint)
            .finish()
    }
}

/// A query string under construction, encoded like OpenCode's client
/// (`location[directory]=...`).
#[derive(Clone, Debug, Default)]
pub struct Query(Vec<(String, String)>);

impl Query {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds one value.
    pub fn with(mut self, key: &str, value: impl ToString) -> Self {
        self.0.push((key.to_owned(), value.to_string()));
        self
    }

    /// Adds an optional value.
    pub fn maybe(self, key: &str, value: Option<impl ToString>) -> Self {
        match value {
            Some(value) => self.with(key, value),
            None => self,
        }
    }

    /// Scopes the request to a folder.
    pub fn location(self, directory: Option<&std::path::Path>) -> Self {
        self.maybe(
            "location[directory]",
            directory.map(|path| path.display().to_string()),
        )
    }
}

impl Api {
    pub fn new(endpoint: Endpoint) -> Result<Self, ApiError> {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|error| ApiError::Transport(error.to_string()))?;
        let streaming = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|error| ApiError::Transport(error.to_string()))?;
        Ok(Self {
            endpoint,
            http,
            streaming,
        })
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    fn request(
        &self,
        client: &reqwest::Client,
        method: Method,
        path: &str,
        query: &Query,
    ) -> reqwest::RequestBuilder {
        let mut url = self.endpoint.join(path);
        if !query.0.is_empty() {
            url.query_pairs_mut().extend_pairs(
                query
                    .0
                    .iter()
                    .map(|(key, value)| (key.as_str(), value.as_str())),
            );
        }
        let mut request = client.request(method, url);
        if let Some(authorization) = self.endpoint.authorization() {
            request = request.header(reqwest::header::AUTHORIZATION, authorization);
        }
        request
    }

    /// `GET` returning JSON.
    pub async fn get(&self, path: &str, query: Query) -> Result<Value, ApiError> {
        let response = self
            .request(&self.http, Method::GET, path, &query)
            .send()
            .await
            .map_err(transport)?;
        decode(response).await.map(Option::unwrap_or_default)
    }

    /// A mutation; `None` for `204 No Content`.
    pub async fn send(
        &self,
        method: Method,
        path: &str,
        query: Query,
        body: Option<Value>,
    ) -> Result<Option<Value>, ApiError> {
        let mut request = self.request(&self.http, method, path, &query);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(transport)?;
        decode(response).await
    }

    pub async fn post(&self, path: &str, body: Value) -> Result<Option<Value>, ApiError> {
        self.send(Method::POST, path, Query::new(), Some(body))
            .await
    }

    /// A `POST` that may take longer than [`REQUEST_TIMEOUT`] (model calls).
    pub async fn post_with_timeout(
        &self,
        path: &str,
        body: Value,
        timeout: Duration,
    ) -> Result<Option<Value>, ApiError> {
        let response = self
            .request(&self.http, Method::POST, path, &Query::new())
            .timeout(timeout)
            .json(&body)
            .send()
            .await
            .map_err(transport)?;
        decode(response).await
    }

    /// An SSE endpoint as a stream of JSON events. The stream ends when the
    /// connection does; an `Err` item is the reason.
    pub async fn sse(
        &self,
        path: &str,
        query: Query,
    ) -> Result<impl Stream<Item = Result<Value, ApiError>> + Send + 'static, ApiError> {
        let response = self
            .request(&self.streaming, Method::GET, path, &query)
            .header(reqwest::header::ACCEPT, "text/event-stream")
            .send()
            .await
            .map_err(transport)?;
        if !response.status().is_success() {
            return Err(status_error(response).await);
        }
        let mut decoder = SseDecoder::default();
        let bytes = response.bytes_stream();
        Ok(bytes
            .map(Some)
            .chain(futures_util::stream::once(async { None }))
            .flat_map(move |chunk| {
                let events: Vec<Result<Value, ApiError>> = match chunk {
                    Some(Ok(bytes)) => match decoder.feed(&bytes) {
                        Ok(events) => events.into_iter().map(Ok).collect(),
                        Err(error) => vec![Err(ApiError::Decode(error.to_string()))],
                    },
                    Some(Err(error)) => vec![Err(transport(error))],
                    None => match decoder.finish() {
                        Ok(events) => events.into_iter().map(Ok).collect(),
                        Err(error) => vec![Err(ApiError::Decode(error.to_string()))],
                    },
                };
                futures_util::stream::iter(events)
            }))
    }
}

fn transport(error: reqwest::Error) -> ApiError {
    ApiError::Transport(error.to_string())
}

async fn decode(response: reqwest::Response) -> Result<Option<Value>, ApiError> {
    if !response.status().is_success() {
        return Err(status_error(response).await);
    }
    if response.status() == reqwest::StatusCode::NO_CONTENT {
        return Ok(None);
    }
    let text = response.text().await.map_err(transport)?;
    if text.trim().is_empty() {
        return Ok(None);
    }
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|error| ApiError::Decode(error.to_string()))
}

async fn status_error(response: reqwest::Response) -> ApiError {
    let status = response.status().as_u16();
    let body: Value = response
        .text()
        .await
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Value::Null);
    let tag = body.get("_tag").and_then(Value::as_str).map(str::to_owned);
    let message = body
        .get("message")
        .or_else(|| body.pointer("/data/message"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| match status {
            401 => "OpenCode rejected the service credentials".to_owned(),
            404 => "not found".to_owned(),
            _ => format!("OpenCode answered {status}"),
        });
    ApiError::Status {
        status,
        tag,
        message: bounded(&message, 500),
    }
}

/// Bounds untrusted text shown to users.
pub fn bounded(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(max).collect();
    out.push('…');
    out
}

/// Unwraps OpenCode's `{ data: ... }` response envelope.
pub fn data(value: Value) -> Value {
    match value {
        Value::Object(mut map) if map.contains_key("data") => {
            map.remove("data").unwrap_or_default()
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_classify_by_status_and_tag() {
        let busy = ApiError::Status {
            status: 409,
            tag: Some("SessionBusyError".into()),
            message: "busy".into(),
        };
        assert!(busy.is_busy() && busy.is_conflict() && !busy.outcome_unknown());
        assert!(ApiError::Transport("reset".into()).outcome_unknown());
        assert!(
            ApiError::Status {
                status: 500,
                tag: None,
                message: String::new()
            }
            .outcome_unknown()
        );
    }

    #[test]
    fn query_encodes_locations_like_opencode() {
        let query = Query::new()
            .location(Some(std::path::Path::new("/work/app")))
            .maybe("limit", Some(5))
            .maybe("cursor", None::<String>);
        assert_eq!(
            query.0,
            vec![
                ("location[directory]".to_owned(), "/work/app".to_owned()),
                ("limit".to_owned(), "5".to_owned())
            ]
        );
    }

    #[test]
    fn data_unwraps_the_envelope() {
        assert_eq!(
            data(serde_json::json!({"data": [1]})),
            serde_json::json!([1])
        );
        assert_eq!(data(serde_json::json!([2])), serde_json::json!([2]));
    }
}
