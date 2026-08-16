//! Inline Protocol secure transport for the Realtime V3 application contract.

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use inline_protocol::proto;
use inline_protocol::secure::binding::{
    create_temporary_key_binding_proof, encode_bind_temporary_auth_key,
};
use inline_protocol::secure::carrier::{
    ObfuscatedClientHeader, create_obfuscated_client_header, is_valid_obfuscated_header,
};
use inline_protocol::secure::handshake::client::{
    ClientHandshakeResult, EstablishedAuthorizationKey, InlineHandshakeClient,
};
use inline_protocol::secure::handshake::{RsaPublicKey, rsa_public_key_fingerprint};
use inline_protocol::secure::{
    AbridgedFrame, Direction, InlineApplicationObject, RecordFields, decode_abridged_frame,
    decode_inline_application_object, decrypt_record, encode_abridged_packet_with_quick_ack,
    encode_inline_invoke, encrypt_record,
};
use prost::Message;
use std::collections::BTreeSet;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio_tungstenite::tungstenite::Message as WsMessage;

const BOOL_TRUE: u32 = 0x9972_75b5;
const RPC_RESULT: u32 = 0xf35c_6d01;
const NEW_SESSION_CREATED: u32 = 0x9ec2_0908;
const MSGS_ACK: u32 = 0x62d6_b459;
const BAD_MSG_NOTIFICATION: u32 = 0xa7ef_f811;
const BAD_SERVER_SALT: u32 = 0xedab_447b;
const VECTOR: u32 = 0x1cb5_c415;

/// Serialized public key entry used by Inline's published RSA key ring.
#[derive(Clone, Debug, serde::Deserialize, serde::Serialize)]
pub struct InlineProtocolPublicKey {
    /// Base64url-encoded unsigned 2048-bit modulus.
    pub modulus: String,
    /// Base64url-encoded unsigned exponent.
    pub exponent: String,
    /// Signed decimal Telegram-compatible fingerprint.
    pub fingerprint: String,
}

impl TryFrom<InlineProtocolPublicKey> for RsaPublicKey {
    type Error = InlineProtocolV3Error;

    fn try_from(value: InlineProtocolPublicKey) -> Result<Self, Self::Error> {
        let modulus = URL_SAFE_NO_PAD
            .decode(value.modulus)
            .map_err(|_| InlineProtocolV3Error::InvalidKey)?;
        let exponent = URL_SAFE_NO_PAD
            .decode(value.exponent)
            .map_err(|_| InlineProtocolV3Error::InvalidKey)?;
        let fingerprint = value
            .fingerprint
            .parse::<i64>()
            .map_err(|_| InlineProtocolV3Error::InvalidKey)?;
        if rsa_public_key_fingerprint(&modulus, &exponent)
            .map_err(|_| InlineProtocolV3Error::InvalidKey)?
            != fingerprint
        {
            return Err(InlineProtocolV3Error::InvalidKey);
        }
        Ok(Self {
            modulus,
            exponent,
            fingerprint,
        })
    }
}

/// Reusable authorization-key material owned by the calling application.
#[derive(Clone)]
pub struct InlineProtocolAuthorization {
    /// Exact 256-byte secret authorization key.
    pub key: [u8; 256],
    /// Telegram-compatible key identifier.
    pub key_id: [u8; 8],
    /// Latest authenticated server salt.
    pub server_salt: i64,
    /// Whether the key is temporary.
    pub temporary: bool,
    /// Authenticated expiry time for temporary keys.
    pub expires_at: Option<i32>,
}

impl std::fmt::Debug for InlineProtocolAuthorization {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("InlineProtocolAuthorization")
            .field("key", &"<redacted>")
            .field("key_id", &self.key_id)
            .field("server_salt", &self.server_salt)
            .field("temporary", &self.temporary)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl From<EstablishedAuthorizationKey> for InlineProtocolAuthorization {
    fn from(value: EstablishedAuthorizationKey) -> Self {
        Self {
            key: value.key,
            key_id: value.key_id,
            server_salt: value.server_salt,
            temporary: value.temporary,
            expires_at: value.expires_at,
        }
    }
}

/// Connection settings for Inline Protocol.
pub struct InlineProtocolV3Options {
    /// `/realtime/v3` WebSocket URL.
    pub url: String,
    /// Pinned RSA public-key ring. It is required only for a fresh handshake.
    pub rsa_public_keys: Vec<RsaPublicKey>,
    /// Existing authorization key used for reconnect.
    pub authorization: Option<InlineProtocolAuthorization>,
    /// Whether a fresh handshake should create a temporary key.
    pub temporary: bool,
    /// Timeout for each carrier response.
    pub request_timeout: Duration,
}

impl InlineProtocolV3Options {
    /// Creates options for a fresh permanent-key handshake.
    pub fn permanent(url: impl Into<String>, rsa_public_keys: Vec<RsaPublicKey>) -> Self {
        Self {
            url: url.into(),
            rsa_public_keys,
            authorization: None,
            temporary: false,
            request_timeout: Duration::from_secs(60),
        }
    }

    /// Creates options for reconnecting with an established key.
    pub fn reconnect(url: impl Into<String>, authorization: InlineProtocolAuthorization) -> Self {
        Self {
            url: url.into(),
            rsa_public_keys: Vec::new(),
            authorization: Some(authorization),
            temporary: false,
            request_timeout: Duration::from_secs(60),
        }
    }
}

/// Failure returned by the secure Realtime V3 connection.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum InlineProtocolV3Error {
    /// The pinned key ring is empty or internally inconsistent.
    #[error("invalid Inline Protocol RSA key ring")]
    InvalidKey,
    /// The peer sent a record that failed cryptographic or structural validation.
    #[error("invalid Inline Protocol record")]
    Protocol,
    /// WebSocket transport failed.
    #[error("websocket error: {0}")]
    WebSocket(#[from] tokio_tungstenite::tungstenite::Error),
    /// Protobuf application payload failed to decode.
    #[error("Inline Schema error: {0}")]
    Schema(#[from] prost::DecodeError),
    /// The server returned an application-level RPC error.
    #[error("Inline RPC error: {0}")]
    Rpc(String),
    /// The response did not match the requested application operation.
    #[error("unexpected Realtime V3 response")]
    UnexpectedResponse,
    /// The peer did not answer before the configured timeout.
    #[error("Inline Protocol response timed out")]
    Timeout,
    /// The connection closed before a response arrived.
    #[error("Inline Protocol connection closed")]
    Closed,
}

type WebSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Stateful, serialized Realtime V3 connection.
pub struct InlineProtocolV3Connection {
    socket: WebSocket,
    carrier: ObfuscatedClientHeader,
    authorization: InlineProtocolAuthorization,
    session_id: i64,
    last_message_id: i64,
    content_count: i32,
    server_unix_millis: i64,
    monotonic_anchor: Instant,
    request_timeout: Duration,
}

impl InlineProtocolV3Connection {
    /// Opens the carrier and performs a fresh handshake or authenticated reconnect.
    pub async fn connect(options: InlineProtocolV3Options) -> Result<Self, InlineProtocolV3Error> {
        if options.authorization.is_none()
            && (options.rsa_public_keys.is_empty()
                || options.rsa_public_keys.iter().any(|key| {
                    rsa_public_key_fingerprint(&key.modulus, &key.exponent)
                        .map(|fingerprint| fingerprint != key.fingerprint)
                        .unwrap_or(true)
                }))
        {
            return Err(InlineProtocolV3Error::InvalidKey);
        }
        let (mut socket, _) = tokio_tungstenite::connect_async(&options.url).await?;
        let mut random_header = [0; 64];
        loop {
            random(&mut random_header)?;
            if is_valid_obfuscated_header(&random_header) {
                break;
            }
        }
        let carrier = create_obfuscated_client_header(&random_header, 1)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        socket
            .send(WsMessage::Binary(carrier.wire_header.to_vec().into()))
            .await?;
        let session_id = random_i64()?;
        let now_seconds = unix_millis()? / 1_000;
        let placeholder = InlineProtocolAuthorization {
            key: [0; 256],
            key_id: [0; 8],
            server_salt: 0,
            temporary: false,
            expires_at: None,
        };
        let mut connection = Self {
            socket,
            carrier,
            authorization: options.authorization.clone().unwrap_or(placeholder),
            session_id,
            last_message_id: 0,
            content_count: 0,
            server_unix_millis: now_seconds * 1_000,
            monotonic_anchor: Instant::now(),
            request_timeout: options.request_timeout,
        };
        if options.authorization.is_none() {
            let mut handshake = InlineHandshakeClient::new(options.rsa_public_keys, 1, |bytes| {
                getrandom::fill(bytes).map_err(|_| inline_protocol::secure::InvalidEncryptedRecord)
            });
            let mut request = handshake
                .begin(options.temporary)
                .map_err(|_| InlineProtocolV3Error::Protocol)?;
            loop {
                let message_id = connection.next_system_message_id()?;
                connection
                    .send_packet(&encode_unencrypted(message_id, &request)?, false)
                    .await?;
                let response = decode_unencrypted(&connection.receive_packet().await?)?;
                match handshake
                    .receive(&response)
                    .map_err(|_| InlineProtocolV3Error::Protocol)?
                {
                    ClientHandshakeResult::Request(next) => request = next,
                    ClientHandshakeResult::Established {
                        authorization,
                        server_time,
                    } => {
                        connection.authorization = authorization.into();
                        connection.server_unix_millis = i64::from(server_time) * 1_000;
                        connection.monotonic_anchor = Instant::now();
                        break;
                    }
                }
            }
        }
        Ok(connection)
    }

    /// Returns a clone suitable for secure host-owned persistence.
    pub fn authorization(&self) -> InlineProtocolAuthorization {
        self.authorization.clone()
    }

    /// Returns the active logical session ID.
    pub fn session_id(&self) -> i64 {
        self.session_id
    }

    /// Invokes one typed Realtime V3 application request.
    pub async fn invoke(
        &mut self,
        request: proto::RealtimeV3Request,
    ) -> Result<proto::RealtimeV3Response, InlineProtocolV3Error> {
        let body = encode_inline_invoke(&request.encode_to_vec(), 3)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let result = self.send_content(body).await?;
        let InlineApplicationObject::Result(payload) = decode_inline_application_object(&result)
            .map_err(|_| InlineProtocolV3Error::Protocol)?
        else {
            return Err(InlineProtocolV3Error::UnexpectedResponse);
        };
        Ok(proto::RealtimeV3Response::decode(payload.as_slice())?)
    }

    /// Begins native authentication without an HTTP login token.
    pub async fn auth_begin(
        &mut self,
        request: proto::AuthBeginRequest,
    ) -> Result<proto::AuthBeginResult, InlineProtocolV3Error> {
        use proto::realtime_v3_request::Body as Request;
        use proto::realtime_v3_response::Body as Response;
        match response_body(
            self.invoke(proto::RealtimeV3Request {
                body: Some(Request::AuthBegin(request)),
            })
            .await?,
        )? {
            Response::AuthBegin(result) => Ok(result),
            Response::RpcError(error) => Err(InlineProtocolV3Error::Rpc(error.message)),
            _ => Err(InlineProtocolV3Error::UnexpectedResponse),
        }
    }

    /// Completes native authentication with a challenge code.
    pub async fn auth_complete(
        &mut self,
        request: proto::AuthCompleteRequest,
    ) -> Result<proto::AuthCompleteResult, InlineProtocolV3Error> {
        use proto::realtime_v3_request::Body as Request;
        use proto::realtime_v3_response::Body as Response;
        match response_body(
            self.invoke(proto::RealtimeV3Request {
                body: Some(Request::AuthComplete(request)),
            })
            .await?,
        )? {
            Response::AuthComplete(result) => Ok(result),
            Response::RpcError(error) => Err(InlineProtocolV3Error::Rpc(error.message)),
            _ => Err(InlineProtocolV3Error::UnexpectedResponse),
        }
    }

    /// Calls an existing Inline RPC through the V3 application bridge.
    pub async fn call_rpc(
        &mut self,
        request: proto::RpcCall,
    ) -> Result<proto::RpcResult, InlineProtocolV3Error> {
        use proto::realtime_v3_request::Body as Request;
        use proto::realtime_v3_response::Body as Response;
        match response_body(
            self.invoke(proto::RealtimeV3Request {
                body: Some(Request::Rpc(request)),
            })
            .await?,
        )? {
            Response::RpcResult(result) => Ok(result),
            Response::RpcError(error) => Err(InlineProtocolV3Error::Rpc(error.message)),
            _ => Err(InlineProtocolV3Error::UnexpectedResponse),
        }
    }

    /// Invokes a typed RPC using the same request mapping as Realtime V2.
    pub async fn call<R>(&mut self, request: R) -> Result<R::Response, InlineProtocolV3Error>
    where
        R: crate::realtime::RpcRequest,
    {
        let result = self
            .call_rpc(proto::RpcCall {
                method: R::METHOD as i32,
                input: Some(request.into_rpc_input()),
            })
            .await?
            .result
            .ok_or(InlineProtocolV3Error::UnexpectedResponse)?;
        R::response_from_rpc_result(result)
            .map_err(|error| InlineProtocolV3Error::Rpc(error.to_string()))
    }

    /// Binds this temporary connection to an authenticated permanent key.
    pub async fn bind_temporary(
        &mut self,
        permanent: &InlineProtocolAuthorization,
    ) -> Result<(), InlineProtocolV3Error> {
        let expires_at = self
            .authorization
            .expires_at
            .ok_or(InlineProtocolV3Error::Protocol)?;
        if !self.authorization.temporary || permanent.temporary {
            return Err(InlineProtocolV3Error::Protocol);
        }
        let message_id = self.next_message_id()?;
        let sequence_number = self.next_sequence(true);
        let nonce = random_i64()?;
        let mut prefix = [0; 16];
        let mut padding = [0; 8];
        random(&mut prefix)?;
        random(&mut padding)?;
        let proof = create_temporary_key_binding_proof(
            &permanent.key,
            &self.authorization.key,
            self.session_id,
            message_id,
            nonce,
            expires_at,
            &prefix,
            &padding,
        )
        .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let body = encode_bind_temporary_auth_key(
            i64::from_le_bytes(permanent.key_id),
            nonce,
            expires_at,
            &proof,
        )
        .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let (_, result) = self
            .send_prepared_content(message_id, sequence_number, body)
            .await?;
        if result.as_slice() != BOOL_TRUE.to_le_bytes() {
            return Err(InlineProtocolV3Error::Protocol);
        }
        Ok(())
    }

    async fn send_content(&mut self, body: Vec<u8>) -> Result<Vec<u8>, InlineProtocolV3Error> {
        let message_id = self.next_message_id()?;
        let sequence_number = self.next_sequence(true);
        Ok(self
            .send_prepared_content(message_id, sequence_number, body)
            .await?
            .1)
    }

    async fn send_prepared_content(
        &mut self,
        mut message_id: i64,
        sequence_number: i32,
        body: Vec<u8>,
    ) -> Result<(i64, Vec<u8>), InlineProtocolV3Error> {
        self.send_encrypted(message_id, sequence_number, &body, true)
            .await?;
        loop {
            let fields = self.receive_encrypted().await?;
            if fields.sequence_number % 2 == 1 {
                self.send_ack(fields.message_id).await?;
            }
            let constructor = read_u32(&fields.body, 0)?;
            if constructor == NEW_SESSION_CREATED {
                self.authorization.server_salt = read_i64(&fields.body, 20)?;
            } else if constructor == MSGS_ACK {
                continue;
            } else if constructor == BAD_MSG_NOTIFICATION || constructor == BAD_SERVER_SALT {
                if read_i64(&fields.body, 4)? != message_id
                    || read_i32(&fields.body, 12)? != sequence_number
                {
                    return Err(InlineProtocolV3Error::Protocol);
                }
                let code = read_i32(&fields.body, 16)?;
                if code == 16 || code == 17 {
                    self.sample_message_id(fields.message_id)?;
                } else if code == 48 && constructor == BAD_SERVER_SALT {
                    self.authorization.server_salt = read_i64(&fields.body, 20)?;
                } else {
                    return Err(InlineProtocolV3Error::Protocol);
                }
                message_id = self.next_message_id()?;
                self.send_encrypted(message_id, sequence_number, &body, true)
                    .await?;
            } else if constructor == RPC_RESULT {
                if read_i64(&fields.body, 4)? == message_id {
                    return Ok((message_id, fields.body[12..].to_vec()));
                }
            } else if let Ok(InlineApplicationObject::Update(_)) =
                decode_inline_application_object(&fields.body)
            {
                continue;
            }
        }
    }

    async fn receive_encrypted(&mut self) -> Result<RecordFields, InlineProtocolV3Error> {
        let packet = self.receive_packet().await?;
        let mut salts = BTreeSet::new();
        salts.insert(self.authorization.server_salt);
        let fields = decrypt_record(
            &packet,
            &self.authorization.key,
            Direction::ServerToClient,
            self.session_id,
            &salts,
            self.server_now_millis() / 1_000,
        )
        .map_err(|_| InlineProtocolV3Error::Protocol)?;
        self.sample_message_id(fields.message_id)?;
        Ok(fields)
    }

    async fn send_ack(&mut self, message_id: i64) -> Result<(), InlineProtocolV3Error> {
        let body = [
            MSGS_ACK.to_le_bytes().as_slice(),
            VECTOR.to_le_bytes().as_slice(),
            1_i32.to_le_bytes().as_slice(),
            message_id.to_le_bytes().as_slice(),
        ]
        .concat();
        let outgoing_id = self.next_message_id()?;
        let sequence = self.next_sequence(false);
        self.send_encrypted(outgoing_id, sequence, &body, false)
            .await
    }

    async fn send_encrypted(
        &mut self,
        message_id: i64,
        sequence_number: i32,
        body: &[u8],
        quick_ack: bool,
    ) -> Result<(), InlineProtocolV3Error> {
        let padding_length = 12 + ((16 - ((32 + body.len() + 12) % 16)) % 16);
        let mut padding = vec![0; padding_length];
        random(&mut padding)?;
        let record = encrypt_record(
            &self.authorization.key,
            Direction::ClientToServer,
            &RecordFields {
                server_salt: self.authorization.server_salt,
                session_id: self.session_id,
                message_id,
                sequence_number,
                body: body.to_vec(),
            },
            &padding,
        )
        .map_err(|_| InlineProtocolV3Error::Protocol)?;
        self.send_packet(&record, quick_ack).await
    }

    async fn send_packet(
        &mut self,
        packet: &[u8],
        quick_ack: bool,
    ) -> Result<(), InlineProtocolV3Error> {
        let frame = encode_abridged_packet_with_quick_ack(packet, quick_ack)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let wire = self.carrier.outbound.process(&frame);
        self.socket.send(WsMessage::Binary(wire.into())).await?;
        Ok(())
    }

    async fn receive_packet(&mut self) -> Result<Vec<u8>, InlineProtocolV3Error> {
        loop {
            let message = tokio::time::timeout(self.request_timeout, self.socket.next())
                .await
                .map_err(|_| InlineProtocolV3Error::Timeout)?
                .ok_or(InlineProtocolV3Error::Closed)??;
            let WsMessage::Binary(wire) = message else {
                continue;
            };
            let clear = self.carrier.inbound.process(&wire);
            match decode_abridged_frame(&clear).map_err(|_| InlineProtocolV3Error::Protocol)? {
                AbridgedFrame::Packet { payload, .. } => return Ok(payload),
                AbridgedFrame::QuickAck(_) => continue,
            }
        }
    }

    fn next_sequence(&mut self, content: bool) -> i32 {
        let value = self.content_count * 2 + i32::from(content);
        if content {
            self.content_count += 1;
        }
        value
    }

    fn next_message_id(&mut self) -> Result<i64, InlineProtocolV3Error> {
        let millis = self.server_now_millis();
        self.next_message_id_at(millis)
    }

    fn next_system_message_id(&mut self) -> Result<i64, InlineProtocolV3Error> {
        self.next_message_id_at(unix_millis()?)
    }

    fn next_message_id_at(&mut self, millis: i64) -> Result<i64, InlineProtocolV3Error> {
        let low = i64::from(random_u32()? & 0x3fff_ffff) << 2;
        let mut candidate = ((millis / 1_000) << 32) | (((millis % 1_000) << 32) / 1_000) | low;
        candidate &= !3;
        if candidate <= self.last_message_id {
            candidate = (self.last_message_id + 4) & !3;
        }
        self.last_message_id = candidate;
        Ok(candidate)
    }

    fn sample_message_id(&mut self, message_id: i64) -> Result<(), InlineProtocolV3Error> {
        if message_id & 1 != 1 {
            return Err(InlineProtocolV3Error::Protocol);
        }
        self.server_unix_millis = (message_id >> 32) * 1_000;
        self.monotonic_anchor = Instant::now();
        Ok(())
    }

    fn server_now_millis(&self) -> i64 {
        self.server_unix_millis + self.monotonic_anchor.elapsed().as_millis() as i64
    }
}

fn response_body(
    response: proto::RealtimeV3Response,
) -> Result<proto::realtime_v3_response::Body, InlineProtocolV3Error> {
    response
        .body
        .ok_or(InlineProtocolV3Error::UnexpectedResponse)
}

fn random(output: &mut [u8]) -> Result<(), InlineProtocolV3Error> {
    getrandom::fill(output).map_err(|_| InlineProtocolV3Error::Protocol)
}

fn random_i64() -> Result<i64, InlineProtocolV3Error> {
    let mut bytes = [0; 8];
    random(&mut bytes)?;
    Ok(i64::from_le_bytes(bytes))
}

fn random_u32() -> Result<u32, InlineProtocolV3Error> {
    let mut bytes = [0; 4];
    random(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn unix_millis() -> Result<i64, InlineProtocolV3Error> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| InlineProtocolV3Error::Protocol)?
        .as_millis() as i64)
}

fn encode_unencrypted(message_id: i64, body: &[u8]) -> Result<Vec<u8>, InlineProtocolV3Error> {
    if body.is_empty() || !body.len().is_multiple_of(4) {
        return Err(InlineProtocolV3Error::Protocol);
    }
    Ok([
        0_i64.to_le_bytes().as_slice(),
        message_id.to_le_bytes().as_slice(),
        (body.len() as i32).to_le_bytes().as_slice(),
        body,
    ]
    .concat())
}

fn decode_unencrypted(packet: &[u8]) -> Result<Vec<u8>, InlineProtocolV3Error> {
    if packet.len() < 24 || read_i64(packet, 0)? != 0 {
        return Err(InlineProtocolV3Error::Protocol);
    }
    let length = read_i32(packet, 16)?;
    if length <= 0 || length % 4 != 0 || packet.len() != 20 + length as usize {
        return Err(InlineProtocolV3Error::Protocol);
    }
    Ok(packet[20..].to_vec())
}

fn read_u32(bytes: &[u8], offset: usize) -> Result<u32, InlineProtocolV3Error> {
    Ok(u32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or(InlineProtocolV3Error::Protocol)?
            .try_into()
            .map_err(|_| InlineProtocolV3Error::Protocol)?,
    ))
}
fn read_i32(bytes: &[u8], offset: usize) -> Result<i32, InlineProtocolV3Error> {
    Ok(i32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or(InlineProtocolV3Error::Protocol)?
            .try_into()
            .map_err(|_| InlineProtocolV3Error::Protocol)?,
    ))
}
fn read_i64(bytes: &[u8], offset: usize) -> Result<i64, InlineProtocolV3Error> {
    Ok(i64::from_le_bytes(
        bytes
            .get(offset..offset + 8)
            .ok_or(InlineProtocolV3Error::Protocol)?
            .try_into()
            .map_err(|_| InlineProtocolV3Error::Protocol)?,
    ))
}
