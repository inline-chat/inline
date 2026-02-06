use futures_util::{SinkExt, StreamExt};
use prost::Message;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use url::Url;

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
    #[error("connection error")]
    ConnectionError,
    #[error("{friendly}")]
    RpcError {
        code: i32,
        error_code: i32,
        message: String,
        friendly: String,
    },
}

pub struct RealtimeClient {
    ws: tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    seq: u32,
    id_gen: IdGenerator,
}

impl RealtimeClient {
    pub async fn connect(url: &str, token: &str) -> Result<Self, RealtimeError> {
        let url = Url::parse(url)?;
        let (ws, _) = connect_async(url).await?;
        let mut client = Self {
            ws,
            seq: 0,
            id_gen: IdGenerator::new(),
        };

        client.send_connection_init(token).await?;
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
                    let friendly = format_rpc_error(error.error_code, &message, error.code);
                    return Err(RealtimeError::RpcError {
                        code: error.code,
                        error_code: error.error_code,
                        message,
                        friendly,
                    });
                }
                Some(proto::server_protocol_message::Body::ConnectionError(_)) => {
                    return Err(RealtimeError::ConnectionError)
                }
                _ => {}
            }
        }
    }

    async fn send_connection_init(&mut self, token: &str) -> Result<(), RealtimeError> {
        let init = proto::ConnectionInit {
            token: token.to_string(),
            build_number: None,
            layer: None,
            client_version: Some(env!("CARGO_PKG_VERSION").to_string()),
        };

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
                Some(proto::server_protocol_message::Body::ConnectionError(_)) => {
                    return Err(RealtimeError::ConnectionError)
                }
                _ => {}
            }
        }
    }

    async fn send_client_message(&mut self, message: proto::ClientMessage) -> Result<(), RealtimeError> {
        let bytes = message.encode_to_vec();
        self.ws.send(WsMessage::Binary(bytes)).await?;
        Ok(())
    }

    async fn read_server_message(&mut self) -> Result<proto::ServerProtocolMessage, RealtimeError> {
        loop {
            let message = self.ws.next().await.ok_or(RealtimeError::ConnectionError)??;
            match message {
                WsMessage::Binary(data) => return Ok(proto::ServerProtocolMessage::decode(&*data)?),
                WsMessage::Text(_) => continue,
                WsMessage::Close(_) => return Err(RealtimeError::ConnectionError),
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

fn format_rpc_error(error_code: i32, message: &str, status_code: i32) -> String {
    let label = match error_code {
        1 => "Bad request",
        2 => "Not authenticated",
        3 => "Rate limited",
        4 => "Internal server error",
        5 => "Invalid peer (chat/user id)",
        6 => "Invalid message id",
        7 => "Invalid user id",
        8 => "User already in chat/space",
        9 => "Invalid space id",
        10 => "Invalid chat id",
        11 => "Invalid email address",
        12 => "Invalid phone number",
        13 => "Space admin required",
        14 => "Space owner required",
        _ => "Unknown RPC error",
    };

    let mut formatted = String::from(label);
    if !message.is_empty() && !message.eq_ignore_ascii_case(label) {
        formatted.push_str(": ");
        formatted.push_str(message);
    }
    if status_code != 0 {
        formatted.push_str(&format!(" (HTTP {status_code})"));
    }
    formatted
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
