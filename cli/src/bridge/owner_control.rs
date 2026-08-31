//! Narrow owner-authenticated control plane for viewer-owned bridge state.
//!
//! This required connection authorizes session links and keeps owner-scoped
//! dialog/follow state synchronized. It never dispatches provider work or
//! authors bot messages.

use super::*;
use inline_client::{
    BackendError, ClientStatus, ClientStore, DialogFollowMode, UpdateDialogFollowModeRequest,
};

pub(super) struct OwnerControl {
    client: InlineClient,
    store: SqliteStore,
    drain: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    authentication_invalidated: tokio::sync::watch::Receiver<bool>,
}

impl OwnerControl {
    #[cfg(test)]
    pub(super) fn for_test(client: InlineClient, store: SqliteStore) -> Self {
        Self {
            client,
            store,
            drain: tokio::sync::Mutex::new(None),
            authentication_invalidated: tokio::sync::watch::channel(false).1,
        }
    }

    pub(super) async fn connect(
        config: &Config,
        paths: &BridgePaths,
        owner_user_id: i64,
        owner_auth: &AuthCredential,
        start_after_current: bool,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        retry_owner_control_connection(|| {
            Self::connect_once(
                config,
                paths,
                owner_user_id,
                owner_auth,
                start_after_current,
            )
        })
        .await
    }

    async fn connect_once(
        config: &Config,
        paths: &BridgePaths,
        owner_user_id: i64,
        owner_auth: &AuthCredential,
        start_after_current: bool,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let store = SqliteStore::open(&paths.owner_client_db)?;
        let backend = SdkBackend::builder()
            .api_base_url(config.api_base_url.clone())
            .realtime_url(config.realtime_url.clone())
            .identity(ClientIdentity::new(
                "agent-bridge-owner-control",
                env!("CARGO_PKG_VERSION"),
            ))
            .enable_realtime_handshake()
            .store(store.clone())
            .build()?;
        let client = InlineClient::builder().backend(backend).build().spawn();
        let mut events = client.take_lossless_events().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "owner control event stream was already claimed",
            )
        })?;
        let mut request = ConnectRequest::new(owner_auth.clone())
            .with_account_namespace(format!("agent-bridge-owner-{owner_user_id}"));
        if start_after_current {
            request = request.start_after_current();
        }
        if let Err(error) = client.connect(request).await {
            // Retire this attempt before retrying; never leave a failed owner
            // client alongside the account's eventual shared connection.
            let _ = tokio::time::timeout(Duration::from_secs(3), client.shutdown()).await;
            return Err(error.into());
        }

        let (authentication_invalidated_tx, authentication_invalidated) =
            tokio::sync::watch::channel(false);
        let drain = tokio::spawn(async move {
            while let Some(delivery) = events.recv_delivery().await {
                let authentication_invalidated =
                    owner_event_invalidates_authentication(delivery.event());
                if let Err(error) = delivery.ack().await {
                    eprintln!(
                        "Owner control event acknowledgement failed: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    break;
                }
                if authentication_invalidated {
                    let _ = authentication_invalidated_tx.send(true);
                    break;
                }
            }
        });
        Ok(Self {
            client,
            store,
            drain: tokio::sync::Mutex::new(Some(drain)),
            authentication_invalidated,
        })
    }

    pub(super) fn authentication_invalidation_receiver(
        &self,
    ) -> tokio::sync::watch::Receiver<bool> {
        self.authentication_invalidated.clone()
    }

    pub(super) async fn follow_mode(
        &self,
        chat_id: i64,
    ) -> Result<Option<DialogFollowMode>, Box<dyn std::error::Error>> {
        Ok(self
            .store
            .dialog(InlineId::new(chat_id))
            .await?
            .and_then(|dialog| dialog.follow_mode))
    }

    pub(super) async fn user(
        &self,
        user_id: i64,
    ) -> Result<Option<inline_client::UserRecord>, Box<dyn std::error::Error>> {
        Ok(self.store.user(InlineId::new(user_id)).await?)
    }

    pub(super) async fn set_follow_mode(
        &self,
        chat_id: i64,
        mode: DialogFollowMode,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.client
            .update_dialog_follow_mode(UpdateDialogFollowModeRequest {
                chat_id: InlineId::new(chat_id),
                mode,
            })
            .await?;
        Ok(())
    }

    pub(super) async fn connect_agent_session(
        &self,
        request: proto::ConnectAgentSessionInput,
    ) -> Result<proto::ConnectAgentSessionResult, Box<dyn std::error::Error>> {
        Ok(self.client.connect_agent_session(request).await?)
    }

    pub(super) async fn get_agent_session(
        &self,
        request: proto::GetAgentSessionInput,
    ) -> Result<proto::GetAgentSessionResult, Box<dyn std::error::Error>> {
        Ok(self.client.get_agent_session(request).await?)
    }

    pub(super) async fn shutdown(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.client.shutdown().await?;
        let Some(drain) = self.drain.lock().await.take() else {
            return Ok(());
        };
        match tokio::time::timeout(Duration::from_secs(3), drain).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => Err(io::Error::other(format!(
                "owner control task failed: {}",
                safe_diagnostic(&error.to_string())
            ))
            .into()),
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "owner control task did not stop",
            )
            .into()),
        }
    }
}

pub(super) async fn retry_owner_control_connection<T, F, Fut>(
    mut connect: F,
) -> Result<T, Box<dyn std::error::Error>>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, Box<dyn std::error::Error>>>,
{
    let mut failures = 0_u32;
    loop {
        match connect().await {
            Ok(control) => return Ok(control),
            Err(error) => {
                failures += 1;
                if owner_control_error_invalidates_authentication(error.as_ref()) || failures >= 3 {
                    return Err(error);
                }
                eprintln!(
                    "Owner connection failed; retrying before starting agents: {}",
                    safe_diagnostic(&error.to_string())
                );
                tokio::time::sleep(provider_restart_delay(failures)).await;
            }
        }
    }
}

pub(super) fn owner_control_error_invalidates_authentication(
    error: &(dyn std::error::Error + 'static),
) -> bool {
    matches!(
        error.downcast_ref::<ClientRequestError>(),
        Some(ClientRequestError::Backend(BackendError {
            category: ClientErrorCategory::AuthExpired
                | ClientErrorCategory::AuthRequired
                | ClientErrorCategory::ReloginRequired,
            ..
        }))
    )
}

fn owner_event_invalidates_authentication(event: &ClientEvent) -> bool {
    matches!(
        event,
        ClientEvent::StatusChanged {
            status: ClientStatus::AuthExpired
                | ClientStatus::AuthRequired
                | ClientStatus::LoggedOut,
            ..
        }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn seeded_owner_requires_a_real_handshake_before_becoming_ready() {
        let directory = tempfile::tempdir().unwrap();
        let paths = BridgePaths::from_root(
            directory.path().to_path_buf(),
            directory.path().join("unused-inline"),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream);
        });
        let config = Config {
            api_base_url: format!("http://{address}/v1"),
            realtime_url: format!("ws://{address}/realtime"),
            data_dir: directory.path().to_path_buf(),
            secrets_path: directory.path().join("unused-auth"),
            state_path: directory.path().join("unused-state"),
            release_manifest_url: None,
            release_install_url: None,
        };
        let auth = AuthCredential::AccessToken {
            token: AuthToken::try_new("synthetic-loopback-owner").unwrap(),
        };
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            OwnerControl::connect_once(&config, &paths, 42, &auth, false),
        )
        .await
        .expect("closed loopback handshake must finish");
        let connected = result.is_ok();
        if let Ok(control) = result {
            let _ = control.shutdown().await;
        }
        server.abort();
        let _ = server.await;
        assert!(
            !connected,
            "an already-seeded owner cannot become ready offline"
        );
    }

    #[tokio::test]
    async fn owner_startup_recovers_transient_failure_without_a_service_restart() {
        let mut attempts = 0;
        let connected = retry_owner_control_connection(|| {
            attempts += 1;
            let attempt = attempts;
            async move {
                if attempt == 1 {
                    Err(ClientRequestError::Backend(BackendError::new(
                        ClientErrorCategory::Network,
                        "synthetic initial timeout",
                    ))
                    .into())
                } else {
                    Ok("connected owner")
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(attempts, 2);
        assert_eq!(connected, "connected owner");
    }

    #[tokio::test]
    async fn owner_startup_does_not_retry_revoked_authority() {
        for category in [
            ClientErrorCategory::AuthExpired,
            ClientErrorCategory::AuthRequired,
            ClientErrorCategory::ReloginRequired,
        ] {
            let mut attempts = 0;
            let result: Result<(), _> = retry_owner_control_connection(|| {
                attempts += 1;
                async move {
                    Err(ClientRequestError::Backend(BackendError::new(category, "revoked")).into())
                }
            })
            .await;
            assert_eq!(attempts, 1);
            assert!(owner_control_error_invalidates_authentication(
                result.unwrap_err().as_ref()
            ));
        }
    }

    #[tokio::test]
    async fn owner_startup_exhaustion_returns_failure_instead_of_missing_control() {
        let mut attempts = 0;
        let result: Result<(), _> = retry_owner_control_connection(|| {
            attempts += 1;
            async {
                Err(ClientRequestError::Backend(BackendError::new(
                    ClientErrorCategory::Network,
                    "synthetic persistent timeout",
                ))
                .into())
            }
        })
        .await;
        assert!(result.is_err());
        assert_eq!(attempts, 3);
    }

    #[test]
    fn owner_control_classifies_terminal_authentication_failures() {
        for category in [
            ClientErrorCategory::AuthExpired,
            ClientErrorCategory::AuthRequired,
            ClientErrorCategory::ReloginRequired,
        ] {
            let error = ClientRequestError::Backend(BackendError::new(category, "redacted"));
            assert!(owner_control_error_invalidates_authentication(&error));
        }

        let network = ClientRequestError::Backend(BackendError::new(
            ClientErrorCategory::Network,
            "redacted",
        ));
        assert!(!owner_control_error_invalidates_authentication(&network));
    }

    #[test]
    fn owner_control_only_stops_for_terminal_authentication_status() {
        for status in [
            ClientStatus::AuthExpired,
            ClientStatus::AuthRequired,
            ClientStatus::LoggedOut,
        ] {
            assert!(owner_event_invalidates_authentication(
                &ClientEvent::StatusChanged {
                    status,
                    failure: None,
                }
            ));
        }

        assert!(!owner_event_invalidates_authentication(
            &ClientEvent::StatusChanged {
                status: ClientStatus::Reconnecting,
                failure: None,
            }
        ));
    }
}
