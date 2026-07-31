//! Narrow owner-authenticated control plane for viewer-owned bridge state.
//!
//! This connection exists only to keep owner-scoped dialog/follow state
//! synchronized. It never dispatches provider work or authors bot messages.

use super::*;
use inline_client::{ClientStore, DialogFollowMode, UpdateDialogFollowModeRequest};

pub(super) struct OwnerControl {
    client: InlineClient,
    store: SqliteStore,
    drain: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl OwnerControl {
    pub(super) async fn connect(
        config: &Config,
        paths: &BridgePaths,
        owner_user_id: i64,
        owner_token: &str,
        start_after_current: bool,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        if owner_token.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "owner control credentials are unavailable; run setup again",
            )
            .into());
        }
        let store = SqliteStore::open(&paths.owner_client_db)?;
        let backend = SdkBackend::builder()
            .api_base_url(config.api_base_url.clone())
            .realtime_url(config.realtime_url.clone())
            .identity(ClientIdentity::new(
                "agent-bridge-owner-control",
                env!("CARGO_PKG_VERSION"),
            ))
            .store(store.clone())
            .build()?;
        let client = InlineClient::builder().backend(backend).build().spawn();
        let mut events = client.take_lossless_events().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "owner control event stream was already claimed",
            )
        })?;
        let mut request = ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new(owner_token)?,
        })
        .with_account_namespace(format!("agent-bridge-owner-{owner_user_id}"));
        if start_after_current {
            request = request.start_after_current();
        }
        client.connect(request).await?;

        let drain = tokio::spawn(async move {
            while let Some(delivery) = events.recv_delivery().await {
                if let Err(error) = delivery.ack().await {
                    eprintln!(
                        "Owner control event acknowledgement failed: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    break;
                }
            }
        });
        Ok(Self {
            client,
            store,
            drain: tokio::sync::Mutex::new(Some(drain)),
        })
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
