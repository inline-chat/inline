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
    decode_inline_application_object, decode_rpc_error_code, decrypt_record,
    encode_abridged_packet_with_quick_ack, encode_inline_invoke, encrypt_record,
};
use prost::Message;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::Message as WsMessage;

const BOOL_TRUE: u32 = 0x9972_75b5;
const RPC_RESULT: u32 = 0xf35c_6d01;
const NEW_SESSION_CREATED: u32 = 0x9ec2_0908;
const MSGS_ACK: u32 = 0x62d6_b459;
const BAD_MSG_NOTIFICATION: u32 = 0xa7ef_f811;
const BAD_SERVER_SALT: u32 = 0xedab_447b;
const PING: u32 = 0x7abe_77ec;
const PONG: u32 = 0x3477_73c5;
const VECTOR: u32 = 0x1cb5_c415;
const SESSION_REVOKED_CLOSE_CODE: u16 = 4401;
const PENDING_UPDATE_CAPACITY: usize = 256;
const PENDING_UPDATE_BYTE_CAPACITY: usize = 8 * 1024 * 1024;
const TEMPORARY_KEY_LIFETIME_SECONDS: i64 = 86_400;
const TEMPORARY_KEY_ROTATION_LEAD_SECONDS: i64 = TEMPORARY_KEY_LIFETIME_SECONDS / 5;

/// Serialized public key entry used by Inline's published RSA key ring.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub struct InlineProtocolPublicKey {
    /// Base64url-encoded unsigned 2048-bit modulus.
    pub modulus: String,
    /// Base64url-encoded unsigned exponent.
    pub exponent: String,
    /// Signed decimal Telegram-compatible fingerprint.
    pub fingerprint: String,
}

/// Inline's overlapping production verification-key ring.
///
/// These are public keys, not credentials. Custom-server callers should continue to supply their
/// own pinned ring through [`InlineProtocolV3Options`].
pub const INLINE_PROTOCOL_PRODUCTION_PUBLIC_RING_JSON: &str = r#"{"rsaPublicKeyRing":[{"modulus":"y4mCEOAFrQU02g6WBGLvsy6hBh9jOfV6Hg6lvKvnRKj2vybdLTISXilcYbN2ItUfXhFf7Tk660OLhD7lBv2Pme9YVmWswHJ9j7PyyIa6klTiBLSADPPCuknvID1X7bX-Ut5IwmJDciSITHy0Qxf5yGnhRWPWOgxWDt4EdwHiOd9uHwCxLn9k8LfIXN2DOT8aPH306IB0IWMsTlnXBZ7om8nZniJG0NWG1u-BJDEk4Hz8eko1cF4wc-naVY4qcDh9zD9iXrbMJ5b8aw2JG11dvJGEBmWqjPcPJy1VqFNAZOxGUf-LXWRTnNuwECRpgvqm5oO_CFfwXUvM5W1Tw7lIVQ","exponent":"AQAB","fingerprint":"-8339382514522710386"},{"modulus":"mHcArJ0brV69p-pgk5aHpEGWMw1sp-fB7CIxqNTQU9_cTBTUzsBykiEEkZfSj1bCYuTkyhPmlsrf4yA9vP8I5rQqf7UGD1Za_W2qbbv3Wv4C3w4yV-bNJUlxG4qokDHszKgDcNumLJq8uIItXnzeg64UzKW2Bm9KikLtJTB-tq18rrNZ43xS5sZK9HHjvO3i--PdpqB0JVSD4VmjIbXHgq7v9czsYbuqlDn4mCj0rCKylQPxCKVrxbtcuP_brwW-foIkjjX8T7Q5Mi_0Zqx-VZZY7AkT8L7LJH5Lgje_IxYQp2zcLjCQf_ZNioCR0xCPMySvJnBTmVwa65wH0alkPQ","exponent":"AQAB","fingerprint":"-3957383261870667958"}]}"#;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublishedPublicKeyRing {
    rsa_public_key_ring: Vec<InlineProtocolPublicKey>,
}

/// Parses and validates Inline's bundled production public-key ring.
pub fn inline_protocol_production_public_key_ring()
-> Result<Vec<InlineProtocolPublicKey>, InlineProtocolV3Error> {
    let ring: PublishedPublicKeyRing =
        serde_json::from_str(INLINE_PROTOCOL_PRODUCTION_PUBLIC_RING_JSON)
            .map_err(|_| InlineProtocolV3Error::InvalidKey)?;
    for key in ring.rsa_public_key_ring.iter().cloned() {
        let _: RsaPublicKey = key.try_into()?;
    }
    Ok(ring.rsa_public_key_ring)
}

/// Returns Inline's bundled production public-key ring in handshake form.
pub fn inline_protocol_production_rsa_keys() -> Result<Vec<RsaPublicKey>, InlineProtocolV3Error> {
    inline_protocol_production_public_key_ring()?
        .into_iter()
        .map(TryInto::try_into)
        .collect()
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
#[derive(Clone, PartialEq, Eq)]
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

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SerializedInlineProtocolAuthorization {
    key: String,
    key_id: String,
    server_salt: i64,
    temporary: bool,
    expires_at: Option<i32>,
}

impl serde::Serialize for InlineProtocolAuthorization {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        SerializedInlineProtocolAuthorization {
            key: URL_SAFE_NO_PAD.encode(self.key),
            key_id: URL_SAFE_NO_PAD.encode(self.key_id),
            server_salt: self.server_salt,
            temporary: self.temporary,
            expires_at: self.expires_at,
        }
        .serialize(serializer)
    }
}

impl<'de> serde::Deserialize<'de> for InlineProtocolAuthorization {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = SerializedInlineProtocolAuthorization::deserialize(deserializer)?;
        let key = URL_SAFE_NO_PAD
            .decode(value.key)
            .map_err(serde::de::Error::custom)?
            .try_into()
            .map_err(|_| serde::de::Error::custom("invalid authorization key length"))?;
        let key_id = URL_SAFE_NO_PAD
            .decode(value.key_id)
            .map_err(serde::de::Error::custom)?
            .try_into()
            .map_err(|_| serde::de::Error::custom("invalid authorization key id length"))?;
        Ok(Self {
            key,
            key_id,
            server_salt: value.server_salt,
            temporary: value.temporary,
            expires_at: value.expires_at,
        })
    }
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
    /// Timeout for opening the WebSocket and for each carrier response.
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
    #[error("Inline RPC error {error_code} (status {status}): {message}")]
    Rpc {
        /// Transport-level status code.
        status: i32,
        /// Stable application error classification.
        error_code: i32,
        /// Human-readable server error message.
        message: String,
    },
    /// The response did not match the requested application operation.
    #[error("unexpected Realtime V3 response")]
    UnexpectedResponse,
    /// The peer did not answer before the configured timeout.
    #[error("Inline Protocol response timed out")]
    Timeout,
    /// Application request bytes were accepted by the local carrier, but no
    /// authoritative result arrived.
    #[error("Inline Protocol request commit outcome is unknown")]
    CommitOutcomeUnknown,
    /// The connection closed before a response arrived.
    #[error("Inline Protocol connection closed")]
    Closed,
    /// The server explicitly invalidated the authenticated account session.
    #[error("Inline Protocol session authorization was revoked")]
    AuthorizationInvalidated,
    /// Application updates arrived faster than an owner could be installed.
    #[error("Inline Protocol pending update capacity exceeded")]
    UpdateBufferOverflow,
}

impl InlineProtocolV3Error {
    /// Returns whether authenticated transport evidence proves that the
    /// active account authorization was revoked.
    pub fn is_authorization_invalidated(&self) -> bool {
        matches!(self, Self::AuthorizationInvalidated)
    }
}

fn rpc_error(error: proto::RpcError) -> InlineProtocolV3Error {
    InlineProtocolV3Error::Rpc {
        status: error.code,
        error_code: error.error_code,
        message: error.message,
    }
}

fn carrier_rpc_error(code: i32) -> InlineProtocolV3Error {
    if code == 504 {
        return InlineProtocolV3Error::CommitOutcomeUnknown;
    }
    InlineProtocolV3Error::Rpc {
        status: code,
        error_code: proto::rpc_error::Code::Unknown as i32,
        message: "Inline Protocol carrier error".into(),
    }
}

fn commit_unknown_after_application_send(error: InlineProtocolV3Error) -> InlineProtocolV3Error {
    match error {
        InlineProtocolV3Error::Timeout
        | InlineProtocolV3Error::Closed
        | InlineProtocolV3Error::WebSocket(_) => InlineProtocolV3Error::CommitOutcomeUnknown,
        other => other,
    }
}

fn classify_application_send_error(
    error: InlineProtocolV3Error,
    read_only: bool,
    write_admitted: bool,
) -> InlineProtocolV3Error {
    if write_admitted && !read_only {
        commit_unknown_after_application_send(error)
    } else {
        error
    }
}

fn request_is_read_only(request: &proto::RealtimeV3Request) -> bool {
    let Some(proto::realtime_v3_request::Body::Rpc(rpc)) = request.body.as_ref() else {
        return false;
    };
    proto::Method::try_from(rpc.method)
        .map(crate::realtime::rpc_method_is_read_only)
        .unwrap_or(false)
}

fn authenticated_application_result_failure(
    read_only: bool,
    error: InlineProtocolV3Error,
) -> InlineProtocolV3Error {
    if read_only {
        error
    } else {
        InlineProtocolV3Error::CommitOutcomeUnknown
    }
}

type WebSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Stateful, serialized Realtime V3 connection.
pub struct InlineProtocolV3Connection {
    url: String,
    socket: WebSocket,
    carrier: ObfuscatedClientHeader,
    authorization: InlineProtocolAuthorization,
    session_id: i64,
    last_message_id: i64,
    content_count: i32,
    server_unix_millis: i64,
    monotonic_anchor: Instant,
    request_timeout: Duration,
    pending_update_payloads: VecDeque<Vec<u8>>,
    pending_update_bytes: usize,
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
        let url = options.url.clone();
        let (mut socket, _) = tokio::time::timeout(
            options.request_timeout,
            tokio_tungstenite::connect_async(&url),
        )
        .await
        .map_err(|_| InlineProtocolV3Error::Timeout)??;
        let mut random_header = [0; 64];
        loop {
            random(&mut random_header)?;
            if is_valid_obfuscated_header(&random_header) {
                break;
            }
        }
        let carrier = create_obfuscated_client_header(&random_header, 1)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        tokio::time::timeout(
            options.request_timeout,
            socket.send(WsMessage::Binary(carrier.wire_header.to_vec().into())),
        )
        .await
        .map_err(|_| InlineProtocolV3Error::Timeout)??;
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
            url,
            socket,
            carrier,
            authorization: options.authorization.clone().unwrap_or(placeholder),
            session_id,
            last_message_id: 0,
            content_count: 0,
            server_unix_millis: now_seconds * 1_000,
            monotonic_anchor: Instant::now(),
            request_timeout: options.request_timeout,
            pending_update_payloads: VecDeque::new(),
            pending_update_bytes: 0,
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
                    .send_packet(&encode_unencrypted(message_id, &request)?, false, None)
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

    /// Opens a replacement carrier with the same endpoint, authorization, and
    /// timeout. Higher-level durable operations can then replay an idempotent
    /// request identity without owning protocol key material themselves.
    pub async fn reconnect(&self) -> Result<Self, InlineProtocolV3Error> {
        let mut options =
            InlineProtocolV3Options::reconnect(self.url.clone(), self.authorization());
        options.request_timeout = self.request_timeout;
        Self::connect(options).await
    }

    /// Returns whether an authenticated temporary key has reached its exact
    /// 80%-of-lifetime rotation boundary, according to the server clock.
    ///
    /// The clock is established by the authenticated handshake and refreshed
    /// from authenticated server message IDs. This is intentionally a
    /// decision helper rather than a second credential owner; the existing
    /// reconnect owner remains responsible for replacing and persisting the
    /// key.
    pub fn temporary_key_rotation_due(&self) -> bool {
        temporary_key_rotation_due_at(
            self.server_now_millis() / 1_000,
            self.authorization.temporary,
            self.authorization.expires_at,
        )
    }

    fn temporary_key_rotation_deadline(&self) -> Option<tokio::time::Instant> {
        if !self.authorization.temporary {
            return None;
        }
        let now = self.server_now_millis();
        let deadline = self
            .authorization
            .expires_at
            .map(|expires_at| (i64::from(expires_at) - TEMPORARY_KEY_ROTATION_LEAD_SECONDS) * 1_000)
            .unwrap_or(now);
        let delay = deadline.saturating_sub(now);
        Some(tokio::time::Instant::now() + Duration::from_millis(delay as u64))
    }

    /// Returns the active logical session ID.
    pub fn session_id(&self) -> i64 {
        self.session_id
    }

    /// Promotes this authenticated connection into the SDK's single
    /// multiplexed session owner for RPCs and continuously delivered updates.
    pub fn into_session(self) -> crate::realtime::RealtimeSession {
        crate::realtime::RealtimeSession::from_inline_protocol_v3(self)
    }

    /// Invokes one typed Realtime V3 application request.
    pub async fn invoke(
        &mut self,
        request: proto::RealtimeV3Request,
    ) -> Result<proto::RealtimeV3Response, InlineProtocolV3Error> {
        let read_only = request_is_read_only(&request);
        let is_rpc = matches!(
            request.body.as_ref(),
            Some(proto::realtime_v3_request::Body::Rpc(_))
        );
        let body = encode_inline_invoke(&request.encode_to_vec(), 3)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let result = self.send_content(body, read_only).await?;
        let InlineApplicationObject::Result(payload) = decode_inline_application_object(&result)
            .map_err(|_| {
                let error = InlineProtocolV3Error::Protocol;
                if is_rpc {
                    authenticated_application_result_failure(read_only, error)
                } else {
                    error
                }
            })?
        else {
            let error = InlineProtocolV3Error::UnexpectedResponse;
            return Err(if is_rpc {
                authenticated_application_result_failure(read_only, error)
            } else {
                error
            });
        };
        proto::RealtimeV3Response::decode(payload.as_slice()).map_err(|error| {
            let error = InlineProtocolV3Error::Schema(error);
            if is_rpc {
                authenticated_application_result_failure(read_only, error)
            } else {
                error
            }
        })
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
            Response::RpcError(error) => Err(rpc_error(error)),
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
            Response::RpcError(error) => Err(rpc_error(error)),
            _ => Err(InlineProtocolV3Error::UnexpectedResponse),
        }
    }

    /// Begins a provider-neutral hosted browser login bound to this permanent key.
    pub async fn auth_begin_browser(
        &mut self,
        request: proto::AuthBeginBrowserRequest,
    ) -> Result<proto::AuthBeginBrowserResult, InlineProtocolV3Error> {
        use proto::realtime_v3_request::Body as Request;
        use proto::realtime_v3_response::Body as Response;
        match response_body(
            self.invoke(proto::RealtimeV3Request {
                body: Some(Request::AuthBeginBrowser(request)),
            })
            .await?,
        )? {
            Response::AuthBeginBrowser(result) => Ok(result),
            Response::RpcError(error) => Err(rpc_error(error)),
            _ => Err(InlineProtocolV3Error::UnexpectedResponse),
        }
    }

    /// Polls a hosted browser login that is bound to this permanent key.
    pub async fn auth_browser_status(
        &mut self,
        request: proto::AuthBrowserStatusRequest,
    ) -> Result<proto::AuthBrowserStatusResult, InlineProtocolV3Error> {
        use proto::realtime_v3_request::Body as Request;
        use proto::realtime_v3_response::Body as Response;
        match response_body(
            self.invoke(proto::RealtimeV3Request {
                body: Some(Request::AuthBrowserStatus(request)),
            })
            .await?,
        )? {
            Response::AuthBrowserStatus(result) => Ok(result),
            Response::RpcError(error) => Err(rpc_error(error)),
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
        let read_only = proto::Method::try_from(request.method)
            .map(crate::realtime::rpc_method_is_read_only)
            .unwrap_or(false);
        let response = self
            .invoke(proto::RealtimeV3Request {
                body: Some(Request::Rpc(request)),
            })
            .await?;
        let body = response_body(response)
            .map_err(|error| authenticated_application_result_failure(read_only, error))?;
        match body {
            Response::RpcResult(result) => Ok(result),
            Response::RpcError(error) => Err(rpc_error(error)),
            _ => Err(authenticated_application_result_failure(
                read_only,
                InlineProtocolV3Error::UnexpectedResponse,
            )),
        }
    }

    /// Invokes a typed RPC using the same request mapping as Realtime V2.
    pub async fn call<R>(&mut self, request: R) -> Result<R::Response, InlineProtocolV3Error>
    where
        R: crate::realtime::RpcRequest,
    {
        let read_only = crate::realtime::rpc_method_is_read_only(R::METHOD);
        let result = self
            .call_rpc(proto::RpcCall {
                method: R::METHOD as i32,
                input: Some(request.into_rpc_input()),
            })
            .await?
            .result
            .ok_or_else(|| {
                authenticated_application_result_failure(
                    read_only,
                    InlineProtocolV3Error::UnexpectedResponse,
                )
            })?;
        R::response_from_rpc_result(result).map_err(|error| {
            authenticated_application_result_failure(
                read_only,
                InlineProtocolV3Error::Rpc {
                    status: 0,
                    error_code: proto::rpc_error::Code::Unknown as i32,
                    message: error.to_string(),
                },
            )
        })
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
            .send_prepared_content(message_id, sequence_number, body, false)
            .await?;
        if result.as_slice() != BOOL_TRUE.to_le_bytes() {
            return Err(InlineProtocolV3Error::Protocol);
        }
        Ok(())
    }

    async fn send_content(
        &mut self,
        body: Vec<u8>,
        read_only: bool,
    ) -> Result<Vec<u8>, InlineProtocolV3Error> {
        let message_id = self.next_message_id()?;
        let sequence_number = self.next_sequence(true);
        Ok(self
            .send_prepared_content(message_id, sequence_number, body, read_only)
            .await?
            .1)
    }

    async fn send_prepared_content(
        &mut self,
        mut message_id: i64,
        sequence_number: i32,
        body: Vec<u8>,
        read_only: bool,
    ) -> Result<(i64, Vec<u8>), InlineProtocolV3Error> {
        let write_admitted = AtomicBool::new(false);
        self.send_encrypted(
            message_id,
            sequence_number,
            &body,
            true,
            Some(&write_admitted),
        )
        .await
        .map_err(|error| {
            classify_application_send_error(
                error,
                read_only,
                write_admitted.load(Ordering::Acquire),
            )
        })?;
        loop {
            let fields = self
                .receive_encrypted()
                .await
                .map_err(|error| classify_application_send_error(error, read_only, true))?;
            if fields.sequence_number % 2 == 1 {
                self.send_ack(fields.message_id)
                    .await
                    .map_err(|error| classify_application_send_error(error, read_only, true))?;
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
                self.send_encrypted(
                    message_id,
                    sequence_number,
                    &body,
                    true,
                    Some(&write_admitted),
                )
                .await
                .map_err(|error| classify_application_send_error(error, read_only, true))?;
            } else if constructor == RPC_RESULT {
                if read_i64(&fields.body, 4)? == message_id {
                    let result = fields.body[12..].to_vec();
                    if let Some(code) = decode_rpc_error_code(&result)
                        .map_err(|_| InlineProtocolV3Error::Protocol)?
                    {
                        return Err(carrier_rpc_error(code));
                    }
                    return Ok((message_id, result));
                }
            } else if let Ok(InlineApplicationObject::Update(payload)) =
                decode_inline_application_object(&fields.body)
            {
                if self.pending_update_payloads.len() >= PENDING_UPDATE_CAPACITY
                    || self.pending_update_bytes.saturating_add(payload.len())
                        > PENDING_UPDATE_BYTE_CAPACITY
                {
                    return Err(InlineProtocolV3Error::UpdateBufferOverflow);
                }
                self.pending_update_bytes += payload.len();
                self.pending_update_payloads.push_back(payload);
                continue;
            }
        }
    }

    async fn receive_encrypted(&mut self) -> Result<RecordFields, InlineProtocolV3Error> {
        let packet = self.receive_packet().await?;
        self.decrypt_received_packet(&packet)
    }

    async fn receive_encrypted_unbounded(&mut self) -> Result<RecordFields, InlineProtocolV3Error> {
        let packet = self.receive_packet_unbounded().await?;
        self.decrypt_received_packet(&packet)
    }

    fn decrypt_received_packet(
        &mut self,
        packet: &[u8],
    ) -> Result<RecordFields, InlineProtocolV3Error> {
        let mut salts = BTreeSet::new();
        salts.insert(self.authorization.server_salt);
        let fields = decrypt_record(
            packet,
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
        self.send_encrypted(outgoing_id, sequence, &body, false, None)
            .await
    }

    async fn send_encrypted(
        &mut self,
        message_id: i64,
        sequence_number: i32,
        body: &[u8],
        quick_ack: bool,
        attempted: Option<&AtomicBool>,
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
        self.send_packet(&record, quick_ack, attempted).await
    }

    async fn send_packet(
        &mut self,
        packet: &[u8],
        quick_ack: bool,
        attempted: Option<&AtomicBool>,
    ) -> Result<(), InlineProtocolV3Error> {
        let frame = encode_abridged_packet_with_quick_ack(packet, quick_ack)
            .map_err(|_| InlineProtocolV3Error::Protocol)?;
        let wire = self.carrier.outbound.process(&frame);
        if let Some(attempted) = attempted {
            // A cancelled or failed sink future can still have handed bytes to
            // the kernel. Mark the request before awaiting it, not after.
            attempted.store(true, Ordering::Release);
        }
        tokio::time::timeout(
            self.request_timeout,
            self.socket.send(WsMessage::Binary(wire.into())),
        )
        .await
        .map_err(|_| InlineProtocolV3Error::Timeout)??;
        Ok(())
    }

    async fn receive_packet(&mut self) -> Result<Vec<u8>, InlineProtocolV3Error> {
        tokio::time::timeout(self.request_timeout, self.receive_packet_unbounded())
            .await
            .map_err(|_| InlineProtocolV3Error::Timeout)?
    }

    async fn receive_packet_unbounded(&mut self) -> Result<Vec<u8>, InlineProtocolV3Error> {
        loop {
            let message = self
                .socket
                .next()
                .await
                .ok_or(InlineProtocolV3Error::Closed)??;
            let wire = match message {
                WsMessage::Binary(wire) => wire,
                WsMessage::Close(Some(frame))
                    if u16::from(frame.code) == SESSION_REVOKED_CLOSE_CODE =>
                {
                    return Err(InlineProtocolV3Error::AuthorizationInvalidated);
                }
                WsMessage::Close(_) => return Err(InlineProtocolV3Error::Closed),
                _ => continue,
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

struct PendingSessionRpc {
    method: proto::Method,
    read_only: bool,
    sequence_number: i32,
    body: Vec<u8>,
    response: oneshot::Sender<Result<proto::rpc_result::Result, crate::realtime::RealtimeError>>,
}

struct PendingSessionPing {
    message_id: i64,
    ping_id: i64,
    sequence_number: i32,
    body: Vec<u8>,
    deadline: tokio::time::Instant,
}

pub(crate) async fn run_inline_protocol_v3_session(
    mut connection: InlineProtocolV3Connection,
    mut commands: mpsc::Receiver<crate::realtime::SessionCommand>,
    events: broadcast::Sender<crate::realtime::RealtimeEvent>,
    closed: watch::Sender<bool>,
) {
    use crate::realtime::{
        DEFAULT_HEARTBEAT_INTERVAL, DEFAULT_HEARTBEAT_TIMEOUT, RealtimeError, RealtimeEvent,
        SessionCommand,
    };

    let mut pending = HashMap::<i64, PendingSessionRpc>::new();
    let mut heartbeat = tokio::time::interval(DEFAULT_HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    heartbeat.tick().await;
    let mut pending_ping: Option<PendingSessionPing> = None;
    let mut authentication_invalidated = false;
    let mut rotation_requested = false;

    while let Some(payload) = connection.pending_update_payloads.pop_front() {
        connection.pending_update_bytes = connection
            .pending_update_bytes
            .saturating_sub(payload.len());
        let event = match realtime_event_from_update_payload(&payload) {
            Ok(event) => event,
            Err(_) => {
                let _ = closed.send(true);
                return;
            }
        };
        if let Some(event) = event {
            let _ = events.send(event);
        }
    }

    loop {
        pending.retain(|_, rpc| !rpc.response.is_closed());
        if rotation_requested && pending.is_empty() {
            break;
        }
        let heartbeat_deadline = pending_ping
            .as_ref()
            .map(|ping| ping.deadline)
            .unwrap_or_else(tokio::time::Instant::now);
        let rotation_deadline = (!rotation_requested)
            .then(|| connection.temporary_key_rotation_deadline())
            .flatten();
        tokio::select! {
            _ = async {
                if let Some(deadline) = rotation_deadline {
                    tokio::time::sleep_until(deadline).await;
                }
            }, if rotation_deadline.is_some() => {
                // Stop admitting new work at the authenticated 80% boundary.
                // Existing RPCs are allowed to settle; their callers retain
                // the normal commit-unknown behavior if the transport closes.
                rotation_requested = true;
            }
            _ = heartbeat.tick() => {
                if pending_ping.is_none() {
                    let ping_id = match random_i64() {
                        Ok(value) => value,
                        Err(_) => break,
                    };
                    let message_id = match connection.next_message_id() {
                        Ok(value) => value,
                        Err(_) => break,
                    };
                    let sequence_number = connection.next_sequence(false);
                    let body = [PING.to_le_bytes().as_slice(), ping_id.to_le_bytes().as_slice()].concat();
                    if connection
                        .send_encrypted(message_id, sequence_number, &body, false, None)
                        .await
                        .is_err()
                    {
                        break;
                    }
                    pending_ping = Some(PendingSessionPing {
                        message_id,
                        ping_id,
                        sequence_number,
                        body,
                        deadline: tokio::time::Instant::now() + DEFAULT_HEARTBEAT_TIMEOUT,
                    });
                }
            }
            _ = tokio::time::sleep_until(heartbeat_deadline), if pending_ping.is_some() => {
                break;
            }
            command = commands.recv(), if !rotation_requested => {
                let Some(SessionCommand::Invoke { method, input, admission, attempted, response }) = command else {
                    break;
                };
                // The timer and command can become ready in the same select
                // turn. Recheck the authenticated clock at the application
                // admission boundary so an exact-boundary command is rejected
                // as known-not-sent instead of leaking onto the old key.
                if connection.temporary_key_rotation_due() {
                    rotation_requested = true;
                    let _ = response.send(Err(RealtimeError::ConnectionClosed));
                    continue;
                }
                if !crate::realtime::admit_session_command(&admission) {
                    continue;
                }
                let request = proto::RealtimeV3Request {
                    body: Some(proto::realtime_v3_request::Body::Rpc(proto::RpcCall {
                        method: method as i32,
                        input: Some(input),
                    })),
                };
                let body = match encode_inline_invoke(&request.encode_to_vec(), 3) {
                    Ok(body) => body,
                    Err(_) => {
                        let _ = response.send(Err(RealtimeError::InlineProtocol {
                            message: "failed to encode application request".into(),
                        }));
                        continue;
                    }
                };
                let message_id = match connection.next_message_id() {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = response.send(Err(realtime_error_from_v3(error)));
                        break;
                    }
                };
                let sequence_number = connection.next_sequence(true);
                // Admission happens immediately before the bounded sink
                // future. A timeout or socket error after this point is
                // conservatively treated as may-have-executed by the
                // session-level retry classifier.
                if let Err(error) = connection
                    .send_encrypted(message_id, sequence_number, &body, true, Some(&attempted))
                    .await
                {
                    let read_only = crate::realtime::rpc_method_is_read_only(method);
                    let error = realtime_send_error_after_admission(
                        realtime_error_from_v3(error),
                        read_only,
                        attempted.load(Ordering::Acquire),
                    );
                    let _ = response.send(Err(error));
                    break;
                }
                pending.insert(message_id, PendingSessionRpc {
                    method,
                    read_only: crate::realtime::rpc_method_is_read_only(method),
                    sequence_number,
                    body,
                    response,
                });
            }
            received = connection.receive_encrypted_unbounded() => {
                let fields = match received {
                    Ok(fields) => fields,
                    Err(error) => {
                        if error.is_authorization_invalidated() {
                            authentication_invalidated = true;
                            let _ = events.send(RealtimeEvent::AuthenticationInvalidated);
                        }
                        break;
                    },
                };
                if fields.sequence_number % 2 == 1
                    && connection.send_ack(fields.message_id).await.is_err()
                {
                    break;
                }
                let constructor = match read_u32(&fields.body, 0) {
                    Ok(value) => value,
                    Err(_) => break,
                };
                if constructor == NEW_SESSION_CREATED {
                    if let Ok(salt) = read_i64(&fields.body, 20) {
                        connection.authorization.server_salt = salt;
                    } else {
                        break;
                    }
                    continue;
                }
                if constructor == MSGS_ACK {
                    continue;
                }
                if constructor == PONG {
                    if fields.body.len() != 20 {
                        break;
                    }
                    let Ok(request_message_id) = read_i64(&fields.body, 4) else { break };
                    let Ok(ping_id) = read_i64(&fields.body, 12) else { break };
                    if pending_ping.as_ref().is_some_and(|pending| {
                        pending.message_id == request_message_id && pending.ping_id == ping_id
                    }) {
                        pending_ping = None;
                        let _ = events.send(RealtimeEvent::Pong { nonce: ping_id as u64 });
                    }
                    continue;
                }
                if constructor == BAD_MSG_NOTIFICATION || constructor == BAD_SERVER_SALT {
                    let (Ok(request_message_id), Ok(sequence_number), Ok(code)) = (
                        read_i64(&fields.body, 4),
                        read_i32(&fields.body, 12),
                        read_i32(&fields.body, 16),
                    ) else { break };
                    if pending_ping.as_ref().is_some_and(|ping| ping.message_id == request_message_id) {
                        let Some(mut ping) = pending_ping.take() else { break };
                        if ping.sequence_number != sequence_number {
                            break;
                        }
                        if code == 48 && constructor == BAD_SERVER_SALT {
                            let Ok(salt) = read_i64(&fields.body, 20) else { break };
                            connection.authorization.server_salt = salt;
                        } else if code != 16 && code != 17 {
                            break;
                        }
                        let Ok(message_id) = connection.next_message_id() else { break };
                        if connection
                            .send_encrypted(message_id, ping.sequence_number, &ping.body, false, None)
                            .await
                            .is_err()
                        {
                            break;
                        }
                        ping.message_id = message_id;
                        pending_ping = Some(ping);
                        continue;
                    }
                    let Some(rpc) = pending.remove(&request_message_id) else { continue };
                    if rpc.sequence_number != sequence_number {
                        break;
                    }
                    if code == 48 && constructor == BAD_SERVER_SALT {
                        let Ok(salt) = read_i64(&fields.body, 20) else { break };
                        connection.authorization.server_salt = salt;
                    } else if code != 16 && code != 17 {
                        break;
                    }
                    let Ok(message_id) = connection.next_message_id() else { break };
                    if connection
                        .send_encrypted(message_id, rpc.sequence_number, &rpc.body, true, None)
                        .await
                        .is_err()
                    {
                        break;
                    }
                    pending.insert(message_id, rpc);
                    continue;
                }
                if constructor == RPC_RESULT {
                    let Ok(request_message_id) = read_i64(&fields.body, 4) else { break };
                    let Some(rpc) = pending.remove(&request_message_id) else { continue };
                    match decode_session_rpc_response(&fields.body[12..]) {
                        Ok(Ok(result)) => {
                            if let Err(error) =
                                crate::realtime::validate_rpc_result_for_method(rpc.method, &result)
                            {
                                let error = authenticated_result_failure(rpc.read_only, error);
                                let _ = rpc.response.send(Err(error));
                                break;
                            }
                            let _ = rpc.response.send(Ok(result));
                            continue;
                        }
                        Ok(Err(error)) => {
                            // A valid application error is request-local and does not
                            // compromise request/result correlation for the session.
                            let _ = rpc.response.send(Err(error));
                            continue;
                        }
                        Err(error) => {
                            // An authenticated rpc_result that cannot be decoded is a session-level
                            // protocol failure. Keeping the socket alive would strand transaction
                            // ownership on a connection whose request/result correlation is no
                            // longer trustworthy.
                            let error = authenticated_result_failure(rpc.read_only, error);
                            let _ = rpc.response.send(Err(error));
                            break;
                        }
                    }
                }
                if let Ok(InlineApplicationObject::Update(payload)) =
                    decode_inline_application_object(&fields.body)
                {
                    let event = match realtime_event_from_update_payload(&payload) {
                        Ok(event) => event,
                        Err(_) => break,
                    };
                    if let Some(event) = event {
                        let _ = events.send(event);
                    }
                }
            }
        }
    }

    for (_, rpc) in pending {
        let error = if authentication_invalidated {
            authentication_invalidated_realtime_error()
        } else {
            RealtimeError::ConnectionClosed
        };
        let _ = rpc.response.send(Err(error));
    }
    let _ = closed.send(true);
}

fn authenticated_result_failure(
    read_only: bool,
    error: crate::realtime::RealtimeError,
) -> crate::realtime::RealtimeError {
    if read_only {
        error
    } else {
        crate::realtime::RealtimeError::CommitOutcomeUnknown
    }
}

fn realtime_send_error_after_admission(
    error: crate::realtime::RealtimeError,
    read_only: bool,
    write_admitted: bool,
) -> crate::realtime::RealtimeError {
    if write_admitted && !read_only {
        match error {
            crate::realtime::RealtimeError::Timeout { .. }
            | crate::realtime::RealtimeError::ConnectionClosed
            | crate::realtime::RealtimeError::WebSocket(_) => {
                crate::realtime::RealtimeError::CommitOutcomeUnknown
            }
            other => other,
        }
    } else {
        error
    }
}

fn decode_session_rpc_response(
    payload: &[u8],
) -> Result<
    Result<proto::rpc_result::Result, crate::realtime::RealtimeError>,
    crate::realtime::RealtimeError,
> {
    use crate::realtime::RealtimeError;
    use proto::realtime_v3_response::Body as ResponseBody;

    if let Some(code) =
        decode_rpc_error_code(payload).map_err(|_| RealtimeError::InlineProtocol {
            message: "invalid carrier rpc error".into(),
        })?
    {
        return Ok(Err(carrier_realtime_rpc_error(code)));
    }

    let InlineApplicationObject::Result(payload) = decode_inline_application_object(payload)
        .map_err(|_| RealtimeError::InlineProtocol {
            message: "invalid application result".into(),
        })?
    else {
        return Err(RealtimeError::InlineProtocol {
            message: "invalid application result".into(),
        });
    };
    let response = proto::RealtimeV3Response::decode(payload.as_slice())?;
    match response.body {
        Some(ResponseBody::RpcResult(result)) => {
            let result = result.result.ok_or(RealtimeError::MissingResult)?;
            Ok(Ok(result))
        }
        Some(ResponseBody::RpcError(error)) => Ok(Err(realtime_rpc_error(error))),
        _ => Err(RealtimeError::InlineProtocol {
            message: "unexpected application response".into(),
        }),
    }
}

fn realtime_event_from_update_payload(
    payload: &[u8],
) -> Result<Option<crate::realtime::RealtimeEvent>, prost::DecodeError> {
    use crate::realtime::RealtimeEvent;

    let update = proto::RealtimeV3Update::decode(payload)?;
    Ok(update.message.and_then(|message| match message.payload {
        Some(proto::server_message::Payload::Update(update)) => {
            Some(RealtimeEvent::Updates(update.updates))
        }
        Some(proto::server_message::Payload::Grid(event)) => Some(RealtimeEvent::Grid(event)),
        Some(proto::server_message::Payload::Bot(event)) => Some(RealtimeEvent::Bot(event)),
        None => None,
    }))
}

fn temporary_key_rotation_due_at(
    server_now_seconds: i64,
    temporary: bool,
    expires_at: Option<i32>,
) -> bool {
    if !temporary {
        return false;
    }
    let Some(expires_at) = expires_at else {
        return true;
    };
    server_now_seconds >= i64::from(expires_at).saturating_sub(TEMPORARY_KEY_ROTATION_LEAD_SECONDS)
}

fn realtime_rpc_error(error: proto::RpcError) -> crate::realtime::RealtimeError {
    let error_name = proto::rpc_error::Code::try_from(error.error_code)
        .map(|code| code.as_str_name().to_owned())
        .unwrap_or_else(|_| "UNKNOWN".into());
    crate::realtime::RealtimeError::RpcError {
        code: error.code,
        error_code: error.error_code,
        friendly: format!("Inline RPC error {error_name} (status {})", error.code),
        error_name,
        message: error.message,
    }
}

fn carrier_realtime_rpc_error(code: i32) -> crate::realtime::RealtimeError {
    if code == 504 {
        return crate::realtime::RealtimeError::CommitOutcomeUnknown;
    }
    if code == 503 {
        return crate::realtime::RealtimeError::RpcError {
            code,
            error_code: proto::rpc_error::Code::Unknown as i32,
            error_name: "REJECTED_BEFORE_EXECUTION".into(),
            message: "Realtime application rejected before execution".into(),
            friendly: "Realtime application rejected before execution (status 503)".into(),
        };
    }
    crate::realtime::RealtimeError::InlineProtocol {
        message: format!("Inline Protocol carrier error {code}"),
    }
}

fn realtime_error_from_v3(error: InlineProtocolV3Error) -> crate::realtime::RealtimeError {
    match error {
        InlineProtocolV3Error::Rpc {
            status,
            error_code,
            message,
        } => realtime_rpc_error(proto::RpcError {
            req_msg_id: 0,
            error_code,
            message,
            code: status,
        }),
        InlineProtocolV3Error::Timeout => crate::realtime::RealtimeError::Timeout {
            operation: "Inline Protocol",
            timeout: Duration::from_secs(60),
        },
        InlineProtocolV3Error::CommitOutcomeUnknown => {
            crate::realtime::RealtimeError::CommitOutcomeUnknown
        }
        InlineProtocolV3Error::Closed => crate::realtime::RealtimeError::ConnectionClosed,
        InlineProtocolV3Error::AuthorizationInvalidated => {
            crate::realtime::RealtimeError::AuthenticationInvalidated
        }
        InlineProtocolV3Error::UpdateBufferOverflow => {
            crate::realtime::RealtimeError::EventLagged { skipped: 1 }
        }
        other => crate::realtime::RealtimeError::InlineProtocol {
            message: other.to_string(),
        },
    }
}

fn authentication_invalidated_realtime_error() -> crate::realtime::RealtimeError {
    crate::realtime::RealtimeError::AuthenticationInvalidated
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::*;
    use inline_protocol::secure::auth_key_id;

    #[test]
    fn authorization_round_trips_without_debugging_key_material() {
        let key = [7_u8; 256];
        let authorization = InlineProtocolAuthorization {
            key,
            key_id: auth_key_id(&key).unwrap(),
            server_salt: 42,
            temporary: true,
            expires_at: Some(1_700_086_400),
        };
        let encoded = serde_json::to_string(&authorization).unwrap();
        assert!(!format!("{authorization:?}").contains(&URL_SAFE_NO_PAD.encode(key)));
        assert_eq!(
            serde_json::from_str::<InlineProtocolAuthorization>(&encoded).unwrap(),
            authorization
        );
    }

    #[test]
    fn unauthenticated_application_rpc_is_request_scoped() {
        assert!(
            !InlineProtocolV3Error::Rpc {
                status: 16,
                error_code: proto::rpc_error::Code::Unauthenticated as i32,
                message: "request rejected".into(),
            }
            .is_authorization_invalidated()
        );
    }

    #[test]
    fn bundled_production_ring_is_valid_and_contains_rotation_overlap() {
        let ring = inline_protocol_production_public_key_ring().unwrap();
        let canonical: PublishedPublicKeyRing = serde_json::from_str(include_str!(
            "../../../packages/protocol/trust-roots/inline-protocol-production.json"
        ))
        .unwrap();
        assert_eq!(ring, canonical.rsa_public_key_ring);
    }

    #[test]
    fn application_deadline_status_remains_an_application_error() {
        let error = proto::RpcError {
            code: 504,
            error_code: proto::rpc_error::Code::InternalError as i32,
            message: "deadline elapsed".into(),
            ..Default::default()
        };
        assert!(matches!(
            rpc_error(error.clone()),
            InlineProtocolV3Error::Rpc { status: 504, .. }
        ));
        assert!(matches!(
            realtime_rpc_error(error),
            crate::realtime::RealtimeError::RpcError { code: 504, .. }
        ));
    }

    #[test]
    fn carrier_deadline_is_commit_unknown_for_direct_requests() {
        let payload = inline_protocol::secure::encode_rpc_error(504, "deadline").unwrap();
        let code = decode_rpc_error_code(&payload).unwrap();
        assert_eq!(code, Some(504));
        assert!(matches!(
            carrier_rpc_error(code.unwrap()),
            InlineProtocolV3Error::CommitOutcomeUnknown
        ));
    }

    #[test]
    fn carrier_preexecution_rejection_remains_request_local() {
        let payload = inline_protocol::secure::encode_rpc_error(503, "overloaded").unwrap();
        let code = decode_rpc_error_code(&payload).unwrap();
        assert_eq!(code, Some(503));
        assert!(matches!(
            carrier_rpc_error(code.unwrap()),
            InlineProtocolV3Error::Rpc { status: 503, .. }
        ));
    }

    #[test]
    fn application_send_classification_requires_write_admission() {
        assert!(matches!(
            classify_application_send_error(InlineProtocolV3Error::Timeout, false, false),
            InlineProtocolV3Error::Timeout
        ));
        assert!(matches!(
            classify_application_send_error(InlineProtocolV3Error::Closed, false, true),
            InlineProtocolV3Error::CommitOutcomeUnknown
        ));
        assert!(matches!(
            classify_application_send_error(InlineProtocolV3Error::Timeout, true, true),
            InlineProtocolV3Error::Timeout
        ));
        assert!(matches!(
            classify_application_send_error(InlineProtocolV3Error::Protocol, false, true,),
            InlineProtocolV3Error::Protocol
        ));
    }

    #[test]
    fn direct_authenticated_result_failure_preserves_mutation_uncertainty() {
        assert!(matches!(
            authenticated_application_result_failure(false, InlineProtocolV3Error::Protocol),
            InlineProtocolV3Error::CommitOutcomeUnknown
        ));
        assert!(matches!(
            authenticated_application_result_failure(true, InlineProtocolV3Error::Protocol),
            InlineProtocolV3Error::Protocol
        ));
    }

    #[test]
    fn actor_send_error_classification_keeps_prewrite_failures_retryable() {
        let timeout = || crate::realtime::RealtimeError::Timeout {
            operation: "Inline Protocol",
            timeout: Duration::from_secs(1),
        };
        assert!(matches!(
            realtime_send_error_after_admission(timeout(), false, false),
            crate::realtime::RealtimeError::Timeout { .. }
        ));
        assert!(matches!(
            realtime_send_error_after_admission(timeout(), false, true),
            crate::realtime::RealtimeError::CommitOutcomeUnknown
        ));
        assert!(matches!(
            realtime_send_error_after_admission(timeout(), true, true),
            crate::realtime::RealtimeError::Timeout { .. }
        ));
    }

    #[test]
    fn maps_v3_push_payloads_into_the_existing_session_event_stream() {
        let update = proto::Update::default();
        let payload = proto::RealtimeV3Update {
            message: Some(proto::ServerMessage {
                payload: Some(proto::server_message::Payload::Update(
                    proto::UpdatesPayload {
                        updates: vec![update.clone()],
                    },
                )),
            }),
        }
        .encode_to_vec();
        assert_eq!(
            realtime_event_from_update_payload(&payload).unwrap(),
            Some(crate::realtime::RealtimeEvent::Updates(vec![update]))
        );
    }

    #[test]
    fn explicit_session_revocation_is_terminal_authentication_failure() {
        assert!(InlineProtocolV3Error::AuthorizationInvalidated.is_authorization_invalidated());
        assert!(!InlineProtocolV3Error::Closed.is_authorization_invalidated());
    }

    #[test]
    fn temporary_key_rotation_uses_the_authenticated_80_percent_boundary() {
        let expires_at = 100_000_i32;
        assert!(!temporary_key_rotation_due_at(
            i64::from(expires_at) - TEMPORARY_KEY_ROTATION_LEAD_SECONDS - 1,
            true,
            Some(expires_at),
        ));
        assert!(temporary_key_rotation_due_at(
            i64::from(expires_at) - TEMPORARY_KEY_ROTATION_LEAD_SECONDS,
            true,
            Some(expires_at),
        ));
        assert!(temporary_key_rotation_due_at(
            i64::from(expires_at) + 1,
            true,
            Some(expires_at),
        ));
        assert!(!temporary_key_rotation_due_at(
            i64::from(expires_at),
            false,
            None,
        ));
        assert!(temporary_key_rotation_due_at(0, true, None));
    }

    #[test]
    fn malformed_or_mismatched_application_results_are_terminal() {
        assert!(matches!(
            decode_session_rpc_response(&[0, 1, 2, 3]),
            Err(crate::realtime::RealtimeError::InlineProtocol { .. })
        ));

        let unexpected = proto::RealtimeV3Response {
            body: Some(proto::realtime_v3_response::Body::AuthBegin(
                proto::AuthBeginResult::default(),
            )),
        };
        let encoded = inline_protocol::secure::encode_inline_result(&unexpected.encode_to_vec())
            .expect("encode application result");
        assert!(matches!(
            decode_session_rpc_response(&encoded),
            Err(crate::realtime::RealtimeError::InlineProtocol { .. })
        ));

        let missing = proto::RealtimeV3Response {
            body: Some(proto::realtime_v3_response::Body::RpcResult(
                proto::RpcResult::default(),
            )),
        };
        let encoded = inline_protocol::secure::encode_inline_result(&missing.encode_to_vec())
            .expect("encode application result");
        assert!(matches!(
            decode_session_rpc_response(&encoded),
            Err(crate::realtime::RealtimeError::MissingResult)
        ));

        let mismatched = proto::rpc_result::Result::GetChats(proto::GetChatsResult::default());
        let mismatch = crate::realtime::validate_rpc_result_for_method(
            proto::Method::SendMessage,
            &mismatched,
        )
        .expect_err("mismatched typed result must fail validation");
        assert!(matches!(
            authenticated_result_failure(false, mismatch),
            crate::realtime::RealtimeError::CommitOutcomeUnknown
        ));

        assert!(matches!(
            authenticated_result_failure(true, crate::realtime::RealtimeError::MissingResult,),
            crate::realtime::RealtimeError::MissingResult
        ));
    }

    #[test]
    fn unauthenticated_application_rpc_does_not_poison_a_healthy_session() {
        let response = proto::RealtimeV3Response {
            body: Some(proto::realtime_v3_response::Body::RpcError(
                proto::RpcError {
                    req_msg_id: 0,
                    error_code: proto::rpc_error::Code::Unauthenticated as i32,
                    message: "request rejected".into(),
                    code: 401,
                },
            )),
        };
        let encoded = inline_protocol::secure::encode_inline_result(&response.encode_to_vec())
            .expect("encode application result");
        assert!(matches!(
            decode_session_rpc_response(&encoded),
            Ok(Err(crate::realtime::RealtimeError::RpcError {
                code: 401,
                ..
            }))
        ));

        let deadline = inline_protocol::secure::encode_inline_result(
            &proto::RealtimeV3Response {
                body: Some(proto::realtime_v3_response::Body::RpcError(
                    proto::RpcError {
                        code: 504,
                        error_code: proto::rpc_error::Code::InternalError as i32,
                        message: "application deadline".into(),
                        ..Default::default()
                    },
                )),
            }
            .encode_to_vec(),
        )
        .unwrap();
        assert!(matches!(
            decode_session_rpc_response(&deadline),
            Ok(Err(crate::realtime::RealtimeError::RpcError {
                code: 504,
                ..
            }))
        ));
    }

    #[test]
    fn carrier_deadline_is_request_local_in_multiplexed_decoder() {
        let payload = inline_protocol::secure::encode_rpc_error(504, "deadline").unwrap();
        assert!(matches!(
            decode_session_rpc_response(&payload),
            Ok(Err(crate::realtime::RealtimeError::CommitOutcomeUnknown))
        ));

        let result = proto::RealtimeV3Response {
            body: Some(proto::realtime_v3_response::Body::RpcResult(
                proto::RpcResult {
                    req_msg_id: 0,
                    result: Some(proto::rpc_result::Result::GetMe(
                        proto::GetMeResult::default(),
                    )),
                },
            )),
        };
        let encoded =
            inline_protocol::secure::encode_inline_result(&result.encode_to_vec()).unwrap();
        assert!(matches!(
            decode_session_rpc_response(&encoded),
            Ok(Ok(proto::rpc_result::Result::GetMe(_)))
        ));
    }

    #[test]
    fn carrier_preexecution_rejection_does_not_poison_multiplexed_decoder() {
        let payload = inline_protocol::secure::encode_rpc_error(503, "overloaded").unwrap();
        assert!(matches!(
            decode_session_rpc_response(&payload),
            Ok(Err(crate::realtime::RealtimeError::RpcError {
                code: 503,
                error_name,
                ..
            })) if error_name == "REJECTED_BEFORE_EXECUTION"
        ));

        let result = proto::RealtimeV3Response {
            body: Some(proto::realtime_v3_response::Body::RpcResult(
                proto::RpcResult {
                    req_msg_id: 0,
                    result: Some(proto::rpc_result::Result::GetMe(
                        proto::GetMeResult::default(),
                    )),
                },
            )),
        };
        let encoded =
            inline_protocol::secure::encode_inline_result(&result.encode_to_vec()).unwrap();
        assert!(matches!(
            decode_session_rpc_response(&encoded),
            Ok(Ok(proto::rpc_result::Result::GetMe(_)))
        ));
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
