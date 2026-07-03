use futures_util::{SinkExt, StreamExt};
use prost::Message;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use url::Url;

use crate::client_info::{self, ClientIdentity};
use crate::protocol::proto;

#[derive(Debug, thiserror::Error)]
pub enum RealtimeError {
    #[error("websocket error: {0}")]
    WebSocket(#[from] tokio_tungstenite::tungstenite::Error),
    #[error("url error: {0}")]
    Url(#[from] url::ParseError),
    #[error("protocol error: {0}")]
    Protocol(#[from] prost::DecodeError),
    #[error("missing rpc result")]
    MissingResult,
    #[error("{friendly}")]
    ConnectionError {
        reason: i32,
        reason_name: String,
        friendly: String,
    },
    #[error("realtime connection closed")]
    ConnectionClosed,
    #[error("{friendly}")]
    RpcError {
        code: i32,
        error_code: i32,
        error_name: String,
        message: String,
        friendly: String,
    },
}

pub struct RealtimeClient {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    seq: u32,
    id_gen: IdGenerator,
}

impl RealtimeClient {
    pub async fn connect(url: &str, token: &str) -> Result<Self, RealtimeError> {
        Self::connect_with_identity(url, token, ClientIdentity::cli()).await
    }

    pub async fn connect_with_identity(
        url: &str,
        token: &str,
        identity: ClientIdentity<'_>,
    ) -> Result<Self, RealtimeError> {
        let url = Url::parse(url)?;
        let mut request = url.into_client_request()?;
        request.headers_mut().insert(
            client_info::CLIENT_TYPE_HEADER,
            HeaderValue::from_str(identity.client_type)
                .unwrap_or_else(|_| HeaderValue::from_static("unknown")),
        );
        request.headers_mut().insert(
            client_info::CLIENT_VERSION_HEADER,
            HeaderValue::from_str(identity.client_version)
                .unwrap_or_else(|_| HeaderValue::from_static("unknown")),
        );
        request.headers_mut().insert(
            "user-agent",
            HeaderValue::from_str(&client_info::user_agent_for(identity))
                .unwrap_or_else(|_| HeaderValue::from_static("inline-cli")),
        );

        let (ws, _) = connect_async(request).await?;
        let mut client = Self {
            ws,
            seq: 0,
            id_gen: IdGenerator::new(),
        };

        client.send_connection_init(token, identity).await?;
        client.wait_for_connection_open().await?;
        Ok(client)
    }

    pub async fn call_rpc(
        &mut self,
        method: proto::Method,
        input: proto::rpc_call::Input,
    ) -> Result<proto::rpc_result::Result, RealtimeError> {
        let rpc_call = proto::RpcCall {
            method: method as i32,
            input: Some(input),
        };
        let message_id = self.next_id();
        let message = proto::ClientMessage {
            id: message_id,
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::RpcCall(rpc_call)),
        };

        self.send_client_message(message).await?;

        loop {
            let message = self.read_server_message().await?;
            match message.body {
                Some(proto::server_protocol_message::Body::RpcResult(result))
                    if result.req_msg_id == message_id =>
                {
                    return result.result.ok_or(RealtimeError::MissingResult);
                }
                Some(proto::server_protocol_message::Body::RpcError(error))
                    if error.req_msg_id == message_id =>
                {
                    let message = error.message;
                    let error_name = rpc_error_code_name(error.error_code);
                    let friendly =
                        format_rpc_error(error.error_code, &error_name, &message, error.code);
                    return Err(RealtimeError::RpcError {
                        code: error.code,
                        error_code: error.error_code,
                        error_name,
                        message,
                        friendly,
                    });
                }
                Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                    return Err(connection_error_from_proto(error));
                }
                _ => {}
            }
        }
    }

    async fn send_connection_init(
        &mut self,
        token: &str,
        identity: ClientIdentity<'_>,
    ) -> Result<(), RealtimeError> {
        let init = connection_init_for_token(token, identity);
        let message = proto::ClientMessage {
            id: self.next_id(),
            seq: self.next_seq(),
            body: Some(proto::client_message::Body::ConnectionInit(init)),
        };

        self.send_client_message(message).await
    }

    async fn wait_for_connection_open(&mut self) -> Result<(), RealtimeError> {
        loop {
            let message = self.read_server_message().await?;
            match message.body {
                Some(proto::server_protocol_message::Body::ConnectionOpen(_)) => return Ok(()),
                Some(proto::server_protocol_message::Body::ConnectionError(error)) => {
                    return Err(connection_error_from_proto(error));
                }
                _ => {}
            }
        }
    }

    async fn send_client_message(
        &mut self,
        message: proto::ClientMessage,
    ) -> Result<(), RealtimeError> {
        let bytes = message.encode_to_vec();
        self.ws.send(WsMessage::Binary(bytes)).await?;
        Ok(())
    }

    async fn read_server_message(&mut self) -> Result<proto::ServerProtocolMessage, RealtimeError> {
        loop {
            let message = self
                .ws
                .next()
                .await
                .ok_or(RealtimeError::ConnectionClosed)??;
            match message {
                WsMessage::Binary(data) => {
                    return Ok(proto::ServerProtocolMessage::decode(&*data)?);
                }
                WsMessage::Text(_) => continue,
                WsMessage::Close(_) => return Err(RealtimeError::ConnectionClosed),
                WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
                _ => continue,
            }
        }
    }

    fn next_seq(&mut self) -> u32 {
        self.seq = self.seq.wrapping_add(1);
        self.seq
    }

    fn next_id(&mut self) -> u64 {
        self.id_gen.next_id()
    }
}

fn connection_init_for_token(token: &str, identity: ClientIdentity<'_>) -> proto::ConnectionInit {
    proto::ConnectionInit {
        token: token.to_string(),
        build_number: None,
        layer: None,
        client_version: Some(identity.client_version.to_string()),
        os_version: client_info::current_os_version(),
    }
}

fn rpc_error_code_name(error_code: i32) -> String {
    proto::rpc_error::Code::try_from(error_code)
        .map(|code| code.as_str_name())
        .unwrap_or("UNKNOWN")
        .to_string()
}

fn format_rpc_error(error_code: i32, error_name: &str, message: &str, status_code: i32) -> String {
    let label = match error_name {
        "UNKNOWN" => "Unknown RPC error",
        "BAD_REQUEST" => "Bad request",
        "UNAUTHENTICATED" => "Not authenticated",
        "RATE_LIMIT" => "Rate limited",
        "INTERNAL_ERROR" => "Internal server error",
        "PEER_ID_INVALID" => "Invalid peer (chat/user id)",
        "MESSAGE_ID_INVALID" => "Invalid message id",
        "USER_ID_INVALID" => "Invalid user id",
        "USER_ALREADY_MEMBER" => "User already in chat/space",
        "SPACE_ID_INVALID" => "Invalid space id",
        "CHAT_ID_INVALID" => "Invalid chat id",
        "EMAIL_INVALID" => "Invalid email address",
        "PHONE_NUMBER_INVALID" => "Invalid phone number",
        "SPACE_ADMIN_REQUIRED" => "Space admin required",
        "SPACE_OWNER_REQUIRED" => "Space owner required",
        "USERNAME_INVALID" => "Invalid username",
        "USERNAME_TAKEN" => "Username already taken",
        "FIRST_NAME_INVALID" => "Invalid first name",
        _ => "Unknown RPC error",
    };

    let mut formatted = String::from(label);
    if error_name == "UNKNOWN" && error_code != 0 {
        formatted.push_str(&format!(" {error_code}"));
    }
    if !message.is_empty() && !message.eq_ignore_ascii_case(label) {
        formatted.push_str(": ");
        formatted.push_str(message);
    }
    if status_code != 0 {
        formatted.push_str(&format!(" (HTTP {status_code})"));
    }
    formatted
}

fn connection_error_from_proto(error: proto::ConnectionError) -> RealtimeError {
    let reason = error.reason;
    let reason_name = proto::connection_error::Reason::try_from(reason)
        .map(|reason| reason.as_str_name())
        .unwrap_or("UNKNOWN")
        .to_string();
    let friendly = format_connection_error(reason, &reason_name);
    RealtimeError::ConnectionError {
        reason,
        reason_name,
        friendly,
    }
}

fn format_connection_error(reason: i32, reason_name: &str) -> String {
    match reason_name {
        "UNAUTHORIZED" => "Realtime connection unauthorized".to_string(),
        "INVALID_AUTH" => "Realtime auth token is invalid".to_string(),
        "SESSION_REVOKED" => "Realtime session was revoked".to_string(),
        "REASON_UNSPECIFIED" => "Realtime connection rejected".to_string(),
        _ => format!("Realtime connection rejected: unknown reason {reason}"),
    }
}

struct IdGenerator {
    last_timestamp: u64,
    sequence: u32,
}

impl IdGenerator {
    fn new() -> Self {
        Self {
            last_timestamp: 0,
            sequence: 0,
        }
    }

    fn next_id(&mut self) -> u64 {
        let timestamp = current_epoch_seconds().saturating_sub(EPOCH_SECONDS);
        if timestamp == self.last_timestamp {
            self.sequence = self.sequence.wrapping_add(1);
        } else {
            self.sequence = 0;
            self.last_timestamp = timestamp;
        }

        (timestamp << 32) | self.sequence as u64
    }
}

const EPOCH_SECONDS: u64 = 1_735_689_600; // 2025-01-01T00:00:00Z

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_error_code_name_uses_stable_proto_name() {
        assert_eq!(
            rpc_error_code_name(proto::rpc_error::Code::PeerIdInvalid as i32),
            "PEER_ID_INVALID"
        );
        assert_eq!(rpc_error_code_name(999), "UNKNOWN");
    }

    #[test]
    fn rpc_error_formatter_covers_new_profile_codes() {
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::UsernameInvalid as i32,
                "USERNAME_INVALID",
                "",
                400
            ),
            "Invalid username (HTTP 400)"
        );
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::UsernameTaken as i32,
                "USERNAME_TAKEN",
                "handle exists",
                409
            ),
            "Username already taken: handle exists (HTTP 409)"
        );
        assert_eq!(
            format_rpc_error(
                proto::rpc_error::Code::FirstNameInvalid as i32,
                "FIRST_NAME_INVALID",
                "",
                400
            ),
            "Invalid first name (HTTP 400)"
        );
    }

    #[test]
    fn connection_error_preserves_proto_reason() {
        let err = connection_error_from_proto(proto::ConnectionError {
            reason: proto::connection_error::Reason::InvalidAuth as i32,
        });

        match err {
            RealtimeError::ConnectionError {
                reason,
                reason_name,
                friendly,
            } => {
                assert_eq!(reason, 2);
                assert_eq!(reason_name, "INVALID_AUTH");
                assert_eq!(friendly, "Realtime auth token is invalid");
            }
            other => panic!("expected connection error, got {other:?}"),
        }
    }

    #[test]
    fn unknown_connection_error_reason_is_preserved() {
        let err = connection_error_from_proto(proto::ConnectionError { reason: 999 });

        match err {
            RealtimeError::ConnectionError {
                reason,
                reason_name,
                friendly,
            } => {
                assert_eq!(reason, 999);
                assert_eq!(reason_name, "UNKNOWN");
                assert_eq!(friendly, "Realtime connection rejected: unknown reason 999");
            }
            other => panic!("expected connection error, got {other:?}"),
        }
    }

    #[test]
    fn connection_init_uses_custom_client_identity() {
        let init =
            connection_init_for_token("token-1", ClientIdentity::new("integration-test", "9.9.9"));

        assert_eq!(init.token, "token-1");
        assert_eq!(init.client_version.as_deref(), Some("9.9.9"));
        assert!(init.build_number.is_none());
        assert!(init.layer.is_none());
    }
}
