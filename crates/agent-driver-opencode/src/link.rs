//! The current connection to the shared service.
//!
//! The OpenCode service can restart under the bridge (an upgrade, `opencode
//! service restart`, a crash) and come back on a new port with a new
//! password. Everything that talks to it (the event bus, the tool host, the
//! sessions) reads the endpoint through one [`Link`], and the bus asks the
//! link to rediscover the service when its connection keeps failing.

use std::sync::RwLock;

use tokio::sync::Mutex;

use crate::api::Api;
use crate::service::{self, ServerInfo, ServiceConfig, ServiceError};

/// The live service connection.
pub struct Link {
    config: ServiceConfig,
    current: RwLock<(Api, ServerInfo)>,
    rediscovering: Mutex<()>,
}

impl Link {
    /// Finds or starts the service.
    pub async fn connect(config: ServiceConfig) -> Result<Self, ServiceError> {
        let (endpoint, info) = service::ensure(&config).await?;
        let api =
            Api::new(endpoint).map_err(|error| ServiceError::Unreachable(error.to_string()))?;
        Ok(Self {
            config,
            current: RwLock::new((api, info)),
            rediscovering: Mutex::new(()),
        })
    }

    /// A link to a known endpoint (tests, explicit server URLs).
    pub fn fixed(api: Api, info: ServerInfo, config: ServiceConfig) -> Self {
        Self {
            config,
            current: RwLock::new((api, info)),
            rediscovering: Mutex::new(()),
        }
    }

    /// The API for the current service.
    pub fn api(&self) -> Api {
        self.current
            .read()
            .unwrap_or_else(|poison| poison.into_inner())
            .0
            .clone()
    }

    /// What the current service reported when the link last found it.
    pub fn info(&self) -> ServerInfo {
        self.current
            .read()
            .unwrap_or_else(|poison| poison.into_inner())
            .1
            .clone()
    }

    /// Finds the service again, starting it if needed. Returns whether the
    /// endpoint changed.
    pub async fn rediscover(&self) -> Result<bool, ServiceError> {
        let _guard = self.rediscovering.lock().await;
        let (endpoint, info) = service::ensure(&self.config).await?;
        let mut current = self
            .current
            .write()
            .unwrap_or_else(|poison| poison.into_inner());
        if current.0.endpoint() == &endpoint && current.1 == info {
            return Ok(false);
        }
        let api =
            Api::new(endpoint).map_err(|error| ServiceError::Unreachable(error.to_string()))?;
        *current = (api, info);
        Ok(true)
    }
}
