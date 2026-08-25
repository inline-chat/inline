//! One owner-authenticated session for CLI setup and bridge provisioning.

use std::io;

use inline_client::{AuthCredential, AuthToken};
use inline_protocol::proto;
use inline_sdk::{
    InlineProtocolAuthorization, InlineProtocolPublicKey, InlineProtocolV3Connection,
    InlineProtocolV3Error, NativeUploadError, NativeUploadInput, RealtimeClient, RealtimeSession,
    RpcRequest, upload_file_v2, upload_file_v3,
};

use crate::auth::{
    AuthStore, temporary_authorization_needs_regeneration, validate_inline_protocol_authorizations,
};
use crate::config::Config;
use crate::identity;

#[allow(clippy::large_enum_variant)]
enum OwnerConnection {
    V2(RealtimeClient),
    V3(InlineProtocolV3Connection),
}

/// The selected owner authority and its sole live realtime connection.
pub(crate) struct OwnerSession {
    connection: OwnerConnection,
    access_token: Option<AuthToken>,
    permanent: Option<InlineProtocolAuthorization>,
    public_keys: Vec<InlineProtocolPublicKey>,
}

impl OwnerSession {
    pub(crate) async fn connect(
        config: &Config,
        credential: AuthCredential,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        match credential {
            AuthCredential::AccessToken { token } => Ok(Self {
                connection: OwnerConnection::V2(
                    identity::connect_realtime(&config.realtime_url, token.expose_secret()).await?,
                ),
                access_token: Some(token),
                permanent: None,
                public_keys: Vec::new(),
            }),
            AuthCredential::InlineProtocolV3 {
                permanent,
                temporary,
                public_keys,
            } => {
                validate_inline_protocol_authorizations(&permanent, &temporary)?;
                let url = format!("{}/v3", config.realtime_url.trim_end_matches('/'));
                let now_seconds = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)?
                    .as_secs() as i64;
                if !temporary_authorization_needs_regeneration(&temporary, now_seconds) {
                    match identity::reconnect_inline_protocol(&url, temporary).await {
                        Ok(mut cached) => match cached.call(proto::GetMeInput {}).await {
                            Ok(_) if !cached.temporary_key_rotation_due() => {
                                return Ok(Self {
                                    connection: OwnerConnection::V3(cached),
                                    access_token: None,
                                    permanent: Some(permanent),
                                    public_keys,
                                });
                            }
                            Ok(_) => {
                                // GetMe refreshed the authenticated server clock; refresh
                                // before exposing a session at the 80% boundary.
                                drop(cached);
                            }
                            Err(error) if temporary_reconnect_can_regenerate(&error) => {
                                drop(cached);
                            }
                            Err(error) => return Err(error.into()),
                        },
                        Err(error) if temporary_reconnect_can_regenerate(&error) => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                if public_keys.is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "Inline Protocol public keys are required to refresh the owner session",
                    )
                    .into());
                }
                let keys = public_keys
                    .iter()
                    .cloned()
                    .map(TryInto::try_into)
                    .collect::<Result<Vec<_>, _>>()?;
                let mut connection =
                    identity::connect_inline_protocol_fresh(&url, keys, true).await?;
                connection.bind_temporary(&permanent).await?;
                connection.call(proto::GetMeInput {}).await?;
                Ok(Self {
                    connection: OwnerConnection::V3(connection),
                    access_token: None,
                    permanent: Some(permanent),
                    public_keys,
                })
            }
        }
    }

    pub(crate) async fn call<R>(
        &mut self,
        request: R,
    ) -> Result<R::Response, Box<dyn std::error::Error>>
    where
        R: RpcRequest,
    {
        match &mut self.connection {
            OwnerConnection::V2(connection) => Ok(connection.call(request).await?),
            OwnerConnection::V3(connection) => Ok(connection.call(request).await?),
        }
    }

    pub(crate) async fn upload(
        &mut self,
        input: NativeUploadInput,
    ) -> Result<proto::UploadComplete, Box<dyn std::error::Error>> {
        match &mut self.connection {
            OwnerConnection::V2(connection) => Ok(upload_file_v2(connection, input, |_| {}).await?),
            OwnerConnection::V3(connection) => {
                match upload_file_v3(connection, input, |_| {}).await {
                    Ok(upload) => Ok(upload),
                    Err(NativeUploadError::V3(error)) => Err(error.into()),
                    Err(error) => Err(error.into()),
                }
            }
        }
    }

    pub(crate) fn credential(&self) -> Result<AuthCredential, Box<dyn std::error::Error>> {
        match &self.connection {
            OwnerConnection::V2(_) => Ok(AuthCredential::AccessToken {
                token: self.access_token.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "V2 owner has no access token")
                })?,
            }),
            OwnerConnection::V3(connection) => Ok(AuthCredential::InlineProtocolV3 {
                permanent: self.permanent.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "V3 owner has no permanent key")
                })?,
                temporary: connection.authorization(),
                public_keys: self.public_keys.clone(),
            }),
        }
    }

    pub(crate) async fn into_realtime_session(
        self,
        config: &Config,
    ) -> Result<RealtimeSession, Box<dyn std::error::Error>> {
        match self.connection {
            OwnerConnection::V2(connection) => {
                drop(connection);
                let token = self.access_token.ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "V2 owner has no access token")
                })?;
                Ok(RealtimeSession::connect_with_identity(
                    &config.realtime_url,
                    token.expose_secret(),
                    identity::client_identity(),
                )
                .await?)
            }
            OwnerConnection::V3(connection) => Ok(connection.into_session()),
        }
    }
}

pub(crate) fn resolve_owner_credential(
    auth_store: &AuthStore,
) -> Result<Option<AuthCredential>, Box<dyn std::error::Error>> {
    if let Some(token) = auth_store.load_token()? {
        return Ok(Some(AuthCredential::AccessToken {
            token: AuthToken::try_new(token)?,
        }));
    }
    let Some((permanent, temporary)) = auth_store.load_inline_protocol_authorizations()? else {
        return Ok(None);
    };
    let public_keys = identity::resolve_inline_protocol_public_key_ring()?;
    Ok(Some(AuthCredential::InlineProtocolV3 {
        permanent,
        temporary,
        public_keys,
    }))
}

pub(crate) fn temporary_reconnect_can_regenerate(error: &InlineProtocolV3Error) -> bool {
    error.is_unauthenticated()
}
