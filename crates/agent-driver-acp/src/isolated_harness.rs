//! Private ACP processes for OpenCode v2 and the pinned durable Amp adapter.
//! OpenCode MCP registrations are directory-scoped. Give each
//! Inline session its own private ACP server so concurrent chats in the same
//! directory cannot inherit another chat's tool capability or permission state.
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};

use crate::{AcpHarness, AcpLaunchDescriptor, require_opencode_v2, spawn_acp_driver};
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    AgentDriver, DriverError, DriverFuture, HostToolConfiguration, ProviderSessionId,
};

const MAX_CATALOG_FOLDERS: usize = 64;

pub struct IsolatedAcpHarness {
    descriptor: AcpLaunchDescriptor,
    bridge_version: String,
    tools: Option<HostToolConfiguration>,
    info: RuntimeInfo,
    epochs: Mutex<HashMap<String, LiveEpoch>>,
    opening: tokio::sync::Mutex<()>,
    catalog_epoch: tokio::sync::Mutex<Option<(PathBuf, Arc<AcpHarness>)>>,
    catalog_sessions: Mutex<HashMap<PathBuf, ProviderSessionId>>,
    stopped: AtomicBool,
}

struct LiveEpoch {
    folder: PathBuf,
    epoch: Weak<AcpHarness>,
}

impl IsolatedAcpHarness {
    pub async fn connect(
        descriptor: AcpLaunchDescriptor,
        bridge_version: impl Into<String>,
        tools: Option<HostToolConfiguration>,
    ) -> Result<Self, DriverError> {
        if !matches!(descriptor.provider_id.as_str(), "opencode" | "amp") {
            return Err(DriverError::Unsupported("isolated ACP provider"));
        }
        reap_session_hosts(&descriptor).await?;
        let bridge_version = bridge_version.into();
        let epoch = launch(&descriptor, &bridge_version, None).await?;
        let info = epoch.describe();
        epoch.shutdown().await?;
        Ok(Self {
            descriptor,
            bridge_version,
            tools,
            info,
            epochs: Mutex::new(HashMap::new()),
            opening: tokio::sync::Mutex::new(()),
            catalog_epoch: tokio::sync::Mutex::new(None),
            catalog_sessions: Mutex::new(HashMap::new()),
            stopped: AtomicBool::new(false),
        })
    }

    pub async fn shutdown(&self) -> Result<(), DriverError> {
        self.stopped.store(true, Ordering::SeqCst);
        let _opening = self.opening.lock().await;
        let mut catalog_epoch = self.catalog_epoch.lock().await;
        let mut epochs: Vec<_> = self
            .epochs
            .lock()
            .unwrap()
            .values()
            .filter_map(|entry| entry.epoch.upgrade())
            .collect();
        if let Some((_, epoch)) = catalog_epoch.take() {
            epochs.push(epoch);
        }
        let mut first_error = None;
        for epoch in epochs {
            if let Err(error) = epoch.shutdown().await {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    // Only tool-free probe identities enter this map. Native chat sessions
    // must never be resumed in a process shared by folder catalog requests.
    async fn open_catalog_epoch(&self, folder: &PathBuf) -> Result<Arc<AcpHarness>, DriverError> {
        let epoch = launch(&self.descriptor, &self.bridge_version, None).await?;
        let cached = self.catalog_sessions.lock().unwrap().get(folder).cloned();
        let mode = cached.map_or(OpenMode::Start, |session| OpenMode::Resume { session });
        let mut spec = OpenSpec {
            mode,
            folder: folder.clone(),
            settings: Default::default(),
            instructions: None,
            title: None,
            after: None,
            output_mode: OutputMode::Detailed,
        };
        let opened = match epoch.open(spec.clone()).await {
            Err(OpenError::NotFound) => {
                self.catalog_sessions.lock().unwrap().remove(folder);
                spec.mode = OpenMode::Start;
                epoch.open(spec).await
            }
            result => result,
        };
        let session = match opened {
            Ok(session) => session,
            Err(error) => {
                let _ = epoch.shutdown().await;
                return Err(match error {
                    OpenError::Driver(error) => error,
                    other => DriverError::Unavailable(other.to_string()),
                });
            }
        };
        let mut sessions = self.catalog_sessions.lock().unwrap();
        if sessions.len() >= MAX_CATALOG_FOLDERS
            && !sessions.contains_key(folder)
            && let Some(oldest) = sessions.keys().next().cloned()
        {
            sessions.remove(&oldest);
        }
        sessions.insert(folder.clone(), session.key().session.clone());
        Ok(epoch)
    }
}

impl Drop for IsolatedAcpHarness {
    fn drop(&mut self) {
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            for epoch in self
                .epochs
                .lock()
                .unwrap()
                .values()
                .filter_map(|entry| entry.epoch.upgrade())
            {
                runtime.spawn(async move {
                    let _ = epoch.shutdown().await;
                });
            }
        }
    }
}

// The CLI owns one factory per installation. Recover its prior session hosts
// once, before opening new epochs; per-session launches must never reap peers.
async fn reap_session_hosts(descriptor: &AcpLaunchDescriptor) -> Result<(), DriverError> {
    let Some(host) = &descriptor.process_host else {
        return Ok(());
    };
    let fail = |error: std::io::Error| {
        DriverError::Unavailable(format!("ACP process host recovery failed: {error}"))
    };
    inline_agent_bridge::reap_stale_process_host(&host.lock_file)
        .await
        .map_err(fail)?;
    let parent = host
        .lock_file
        .parent()
        .ok_or_else(|| DriverError::Unavailable("ACP process host directory is missing".into()))?;
    let prefix = format!("{}-", descriptor.provider_id);
    for entry in std::fs::read_dir(parent).map_err(fail)? {
        let entry = entry.map_err(fail)?;
        let name = entry.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_prefix(&prefix))
            .and_then(|name| name.strip_suffix(".process.lock"))
        else {
            continue;
        };
        if uuid::Uuid::parse_str(id).is_err() {
            continue;
        }
        let path = entry.path();
        inline_agent_bridge::reap_stale_process_host(&path)
            .await
            .map_err(fail)?;
        std::fs::remove_file(&path).map_err(fail)?;
    }
    Ok(())
}

async fn launch(
    descriptor: &AcpLaunchDescriptor,
    bridge_version: &str,
    tools: Option<HostToolConfiguration>,
) -> Result<Arc<AcpHarness>, DriverError> {
    let mut descriptor = descriptor.clone();
    // Process hosts must not reap another chat's live child under a shared lock.
    if let Some(host) = descriptor.process_host.as_mut() {
        host.lock_file.set_file_name(format!(
            "{}-{}.process.lock",
            descriptor.provider_id,
            uuid::Uuid::new_v4()
        ));
    }
    let lock_file = descriptor
        .process_host
        .as_ref()
        .map(|host| host.lock_file.clone());
    let provider = descriptor.provider_id.clone();
    let path = descriptor.program.clone();
    let spawned = spawn_acp_driver(descriptor, bridge_version)
        .await
        .map_err(|error| DriverError::Unavailable(error.to_string()))?;
    if let Some(lock_file) = lock_file {
        let status = spawned.process_status.clone();
        tokio::spawn(async move {
            if status.wait().await.is_ok() {
                let _ = std::fs::remove_file(lock_file);
            }
        });
    }
    let reported = spawned.driver.agent_version().unwrap_or_default();
    let version = if provider.as_str() == "opencode" {
        require_opencode_v2(reported).map(|version| version.to_string())
    } else if matches!(crate::provider_support("amp").map(|support| support.distribution), Some(crate::AcpDistribution::EmbeddedAdapter(pin)) if pin.version == reported)
        && spawned.driver.capabilities().resume_session
    {
        Ok(reported.to_owned())
    } else {
        Err(
            "Amp bridge v2 requires the current durable ACP adapter; rerun `inline setup amp`"
                .into(),
        )
    };
    let version = match version {
        Ok(version) => version,
        Err(error) => {
            let _ = spawned.driver.shutdown().await;
            return Err(DriverError::Unavailable(error));
        }
    };
    if let Some(tools) = tools
        && let Err(error) = spawned.driver.configure_host_tools(tools)
    {
        let _ = spawned.driver.shutdown().await;
        return Err(error);
    }
    Ok(Arc::new(AcpHarness::from_spawned(
        spawned,
        provider,
        ExecutableInfo {
            path,
            source: ExecutableSource::Path,
            version: Some(version),
            sha256: None,
            other_installs: Vec::new(),
        },
        bridge_version,
    )))
}

impl HarnessDriver for IsolatedAcpHarness {
    fn describe(&self) -> RuntimeInfo {
        self.info.clone()
    }

    fn catalog<'a>(&'a self, mut scope: CatalogScope) -> DriverFuture<'a, Catalog> {
        Box::pin(async move {
            if self.stopped.load(Ordering::SeqCst) {
                return Err(DriverError::Unavailable("ACP harness stopped".into()));
            }
            let folder = scope.folder.clone().unwrap_or_else(|| PathBuf::from("/"));
            let existing = self
                .epochs
                .lock()
                .unwrap()
                .iter()
                .find_map(|(session, entry)| {
                    if (scope.folder.is_some() && entry.folder != folder)
                        || scope
                            .session
                            .as_ref()
                            .is_some_and(|requested| requested.as_str() != session)
                    {
                        return None;
                    }
                    let epoch = entry.epoch.upgrade()?;
                    if epoch
                        .process_status()
                        .is_some_and(|status| status.is_finished())
                    {
                        return None;
                    }
                    Some((session.clone(), entry.folder.clone(), epoch))
                });
            if let Some((session, folder, epoch)) = existing {
                scope.folder = Some(folder);
                scope.session = Some(
                    inline_agent_bridge::ProviderSessionId::new(session)
                        .map_err(|error| DriverError::Protocol(error.to_string()))?,
                );
                return epoch.catalog(scope).await;
            }
            if scope.session.is_some() {
                return Err(DriverError::InvalidSession(
                    "ACP session catalog is unavailable".into(),
                ));
            }
            // One retained, tool-free probe keeps repeated picker reads from
            // creating durable junk sessions. It never blocks chat opens.
            // Switching folders replaces the probe, bounding retained processes.
            let mut probe = self.catalog_epoch.lock().await;
            if self.stopped.load(Ordering::SeqCst) {
                return Err(DriverError::Unavailable("ACP harness stopped".into()));
            }
            if probe.as_ref().is_some_and(|(current, epoch)| {
                current != &folder
                    || epoch
                        .process_status()
                        .is_some_and(|status| status.is_finished())
            }) && let Some((_, epoch)) = probe.take()
            {
                let _ = epoch.shutdown().await;
            }
            if probe.is_none() {
                let epoch = self.open_catalog_epoch(&folder).await?;
                *probe = Some((folder, epoch));
            }
            // A detached native session has no live metadata here. Probe the
            // folder without attaching its conversation to this shared process.
            scope.session = None;
            let result = probe.as_ref().unwrap().1.catalog(scope).await;
            if result.is_err()
                && let Some((_, epoch)) = probe.take()
            {
                let _ = epoch.shutdown().await;
            }
            result
        })
    }

    fn sessions<'a>(&'a self, _query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async { Ok(SessionPage::default()) })
    }

    fn open<'a>(&'a self, spec: OpenSpec) -> HarnessFuture<'a, Arc<dyn Session>, OpenError> {
        Box::pin(async move {
            let _opening = self.opening.lock().await;
            if self.stopped.load(Ordering::SeqCst) {
                return Err(OpenError::Driver(DriverError::Unavailable(
                    "ACP harness stopped".into(),
                )));
            }
            if let OpenMode::Resume { session } = &spec.mode {
                let held = self
                    .epochs
                    .lock()
                    .unwrap()
                    .get(session.as_str())
                    .and_then(|entry| entry.epoch.upgrade())
                    .is_some_and(|epoch| {
                        epoch
                            .process_status()
                            .is_some_and(|status| !status.is_finished())
                    });
                if held {
                    return Err(OpenError::Driver(DriverError::Unavailable(
                        "ACP session is already open in this bridge".into(),
                    )));
                }
            }
            let epoch = launch(&self.descriptor, &self.bridge_version, self.tools.clone())
                .await
                .map_err(OpenError::Driver)?;
            let folder = spec.folder.clone();
            let session = match epoch.open(spec).await {
                Ok(session) => session,
                Err(error) => {
                    let _ = epoch.shutdown().await;
                    return Err(error);
                }
            };
            let mut epochs = self.epochs.lock().unwrap();
            epochs.retain(|_, entry| entry.epoch.strong_count() > 0);
            epochs.insert(
                session.key().session.to_string(),
                LiveEpoch {
                    folder,
                    epoch: Arc::downgrade(&epoch),
                },
            );
            Ok(Arc::new(IsolatedAcpSession { session, epoch }) as Arc<dyn Session>)
        })
    }
}

struct IsolatedAcpSession {
    session: Arc<dyn Session>,
    epoch: Arc<AcpHarness>,
}
impl Session for IsolatedAcpSession {
    fn key(&self) -> &SessionKey {
        self.session.key()
    }
    fn availability(&self) -> AvailabilityMatrix {
        self.session.availability()
    }
    fn events(&self) -> EventStream {
        self.session.events()
    }
    fn send<'a>(&'a self, input: Input) -> HarnessFuture<'a, InputReceipt, SendError> {
        self.session.send(input)
    }
    fn control<'a>(&'a self, op: Op) -> HarnessFuture<'a, OpOutcome, OpError> {
        self.session.control(op)
    }
    fn live_work(&self) -> LiveWork {
        self.session.live_work()
    }
    fn release<'a>(&'a self) -> HarnessFuture<'a, Released, OpError> {
        Box::pin(async move {
            let cancelled_interactions = self.session.live_work().interactions;
            let released = self.session.release().await;
            // This process belongs to this session alone; killing/reaping it
            // confirms release without interrupting another Inline chat.
            let shutdown = self.epoch.shutdown().await;
            if !self
                .epoch
                .process_status()
                .is_some_and(|status| status.is_finished())
            {
                shutdown.map_err(OpError::Driver)?;
            }
            // A cancellation or transport error cannot retain ownership after
            // this session's process has been confirmed stopped.
            let mut released = released.unwrap_or_else(|_| Released {
                key: self.session.key().clone(),
                outcome: ReleaseOutcome::NativeReleased,
                cancelled_interactions,
                pending_inputs: Vec::new(),
                stopped_children: Vec::new(),
            });
            released.outcome = ReleaseOutcome::NativeReleased;
            Ok(released)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn startup_recovers_only_owned_session_locks() {
        for (provider, other_provider) in [("opencode", "amp"), ("amp", "opencode")] {
            let root = tempfile::tempdir().unwrap();
            let owned = root
                .path()
                .join(format!("{provider}-{}.process.lock", uuid::Uuid::new_v4()));
            let other = root.path().join(format!(
                "{other_provider}-{}.process.lock",
                uuid::Uuid::new_v4()
            ));
            let unrelated = root
                .path()
                .join(format!("{provider}-not-a-uuid.process.lock"));
            for path in [&owned, &other, &unrelated] {
                std::fs::write(path, "").unwrap();
            }
            let mut descriptor = crate::provider_support(provider)
                .unwrap()
                .launch_descriptor(None);
            descriptor.process_host = Some(inline_agent_bridge::ProcessHostConfig {
                executable: "inline".into(),
                lock_file: root.path().join("provider.process.lock"),
                provider_id: provider.into(),
            });
            reap_session_hosts(&descriptor).await.unwrap();
            assert!(!owned.exists());
            assert!(other.exists());
            assert!(unrelated.exists());
        }
    }
}
