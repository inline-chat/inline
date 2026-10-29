//! Retained service parent. Candidate failures never have to run their own rollback.
use super::{
    BridgePaths,
    service::{self, ControlCommand},
    unix_now,
};
use crate::{
    config::Config,
    update::{
        self, Artifact, Store, UpdateError,
        store::{atomic_json, read_json},
    },
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::process::{Child, Command};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Activation {
    pub schema_version: u32,
    pub current: Artifact,
    pub previous: Option<Artifact>,
    pub candidate: Option<Artifact>,
    pub phase: String,
    pub last_activation: Option<u64>,
    #[serde(default)]
    pub rejected: Vec<String>,
    pub failure: Option<String>,
}

fn journal(paths: &BridgePaths) -> PathBuf {
    paths.root.join("activation.json")
}
pub(super) fn enabled(paths: &BridgePaths) -> bool {
    journal(paths).is_file()
}
fn data_root(paths: &BridgePaths) -> Result<PathBuf, UpdateError> {
    let parent = paths
        .root
        .parent()
        .ok_or_else(|| std::io::Error::other("missing bridge parent"))?;
    let data = if parent.file_name().is_some_and(|name| name == "accounts") {
        parent.parent().and_then(Path::parent)
    } else {
        parent.parent()
    };
    data.map(Path::to_path_buf)
        .ok_or_else(|| std::io::Error::other("missing runtime root").into())
}

pub(super) fn enroll(paths: &BridgePaths) -> Result<(), UpdateError> {
    let store = Store::new(&data_root(paths)?);
    let artifact = update::retain_running_binary(&store)?;
    if enabled(paths) {
        let current: Activation = read_json(&journal(paths))?;
        if update::newer(&artifact.version, &current.current.version)? {
            store.edit(|state| {
                state.staged = Some(artifact);
                state.outcome = "staged".into();
                Ok(())
            })?;
        }
    } else {
        atomic_json(
            &journal(paths),
            &Activation {
                schema_version: 1,
                current: artifact,
                previous: None,
                candidate: None,
                phase: "committed".into(),
                last_activation: None,
                rejected: Vec::new(),
                failure: None,
            },
        )?;
    }
    Ok(())
}

fn launch(artifact: &Artifact, paths: &BridgePaths, store: &Store) -> Result<Child, UpdateError> {
    update::validate_cached(store, artifact)?;
    let mut command = Command::new(&artifact.executable);
    command
        .args(["bridge", "run", "--config"])
        .arg(&paths.config)
        .env(
            "INLINE_DATA_DIR",
            store
                .root
                .parent()
                .ok_or_else(|| std::io::Error::other("missing runtime data root"))?,
        )
        .stdin(Stdio::null())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    Ok(command.spawn()?)
}

#[derive(Clone, Copy)]
struct TrialPolicy {
    probation: Duration,
    deadline: Duration,
    poll: Duration,
    retry: Duration,
    stop: Duration,
}
const TRIAL: TrialPolicy = TrialPolicy {
    probation: Duration::from_secs(60),
    deadline: Duration::from_secs(120),
    poll: Duration::from_secs(2),
    retry: Duration::from_secs(2),
    stop: Duration::from_secs(30),
};

async fn stop(
    child: &mut Child,
    paths: &BridgePaths,
    secrets: &super::AccountBridgeSecrets,
) -> Result<(), UpdateError> {
    stop_with_timeout(child, paths, secrets, TRIAL.stop).await
}

async fn stop_with_timeout(
    child: &mut Child,
    paths: &BridgePaths,
    secrets: &super::AccountBridgeSecrets,
    timeout: Duration,
) -> Result<(), UpdateError> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    let _ = service::control_request(paths, secrets, ControlCommand::Shutdown).await;
    if tokio::time::timeout(timeout, child.wait()).await.is_err() {
        // Callers use this only after an authenticated drain or explicit service stop.
        child.start_kill()?;
        child.wait().await?;
    }
    Ok(())
}

fn reject(state: &mut Activation, candidate: &Artifact, reason: &str) {
    state.rejected.push(candidate.sha256.clone());
    if state.rejected.len() > 32 {
        state.rejected.remove(0);
    }
    state.candidate = None;
    state.phase = "rolled_back".into();
    state.failure = Some(reason.into());
}

async fn local_trial(
    child: &mut Child,
    candidate: &Artifact,
    paths: &BridgePaths,
    secrets: &super::AccountBridgeSecrets,
    policy: TrialPolicy,
) -> Result<(), UpdateError> {
    let deadline = tokio::time::Instant::now() + policy.deadline;
    let mut ready_since = None;
    loop {
        if let Some(status) = child.try_wait()? {
            let setup = super::FailureLedger::service(paths)
                .load()
                .is_some_and(|entry| entry.needs_setup);
            if status.success() && setup {
                return Ok(());
            }
            return Err(UpdateError::Verification("candidate_exit"));
        }
        let responsive = service::control_request(paths, secrets, ControlCommand::Status)
            .await
            .is_ok_and(|response| {
                Some(response.process_id) == child.id() && response.cli_version == candidate.version
            });
        if responsive {
            let start = *ready_since.get_or_insert_with(tokio::time::Instant::now);
            if start.elapsed() >= policy.probation {
                return Ok(());
            }
        } else {
            ready_since = None;
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(UpdateError::Verification("local_startup"));
        }
        tokio::time::sleep(policy.poll).await;
    }
}

async fn activate(
    state: &mut Activation,
    candidate: Artifact,
    old: Option<&mut Child>,
    paths: &BridgePaths,
    store: &Store,
    secrets: &super::AccountBridgeSecrets,
    channel: &str,
    policy: TrialPolicy,
) -> Result<Child, UpdateError> {
    update::validate_cached(store, &candidate)?;
    if candidate.minimum_reader_schema_version > state.current.bridge_schema_version {
        return Err(UpdateError::Verification("storage_maintenance_required"));
    }
    state.phase = "trial".into();
    state.candidate = Some(candidate.clone());
    atomic_json(&journal(paths), state)?;
    if let Some(old) = old {
        stop_with_timeout(old, paths, secrets, policy.stop).await?;
    }
    let mut failure = "candidate_launch";
    for _ in 0..3 {
        match launch(&candidate, paths, store) {
            Ok(mut child) => {
                match local_trial(&mut child, &candidate, paths, secrets, policy).await {
                    Ok(()) => {
                        let from = state.current.version.clone();
                        state.previous = Some(state.current.clone());
                        state.current = candidate;
                        state.candidate = None;
                        state.phase = "committed".into();
                        state.failure = None;
                        state.last_activation = Some(unix_now());
                        atomic_json(&journal(paths), state)?;
                        crate::telemetry::report_update(
                            "activated",
                            channel,
                            &from,
                            &state.current.version,
                            "committed",
                        );
                        return Ok(child);
                    }
                    Err(error) => {
                        failure = error.stage();
                        let _ = stop_with_timeout(&mut child, paths, secrets, policy.stop).await;
                    }
                }
            }
            Err(_) => break,
        }
        tokio::time::sleep(policy.retry).await;
    }
    reject(state, &candidate, failure);
    atomic_json(&journal(paths), state)?;
    crate::telemetry::report_update(
        "rolled_back",
        channel,
        &candidate.version,
        &state.current.version,
        failure,
    );
    launch(&state.current, paths, store)
}

fn recover_interrupted(
    state: &mut Activation,
    paths: &BridgePaths,
    channel: &str,
) -> Result<(), UpdateError> {
    if state.phase == "trial" {
        if let Some(candidate) = state.candidate.clone() {
            reject(state, &candidate, "interrupted_trial");
            atomic_json(&journal(paths), state)?;
            crate::telemetry::report_update(
                "rolled_back",
                channel,
                &candidate.version,
                &state.current.version,
                "interrupted_trial",
            );
        }
    }
    Ok(())
}

fn pending(
    state: &mut Activation,
    candidate: Option<&Artifact>,
    phase: &str,
    paths: &BridgePaths,
) -> Result<(), UpdateError> {
    if state.candidate.as_ref() != candidate || state.phase != phase {
        state.candidate = candidate.cloned();
        state.phase = phase.into();
        atomic_json(&journal(paths), state)?;
    }
    Ok(())
}

pub(super) async fn run(config_path: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let paths = BridgePaths::for_config_path(&fs::canonicalize(config_path)?)?;
    super::ensure_private_dir(&paths.root)?;
    let _lock = crate::update::store::lock(&paths.root.join("supervisor.lock"))?;
    let (_, secrets) = super::load_account_files(&paths)?;
    let store = Store::new(&data_root(&paths)?);
    let mut config = Config::load();
    config.data_dir = data_root(&paths)?;
    config.state_path = config.data_dir.join("state.json");
    let mut state: Activation = read_json(&journal(&paths))?;
    if state.schema_version != 1 {
        return Err("unsupported activation journal".into());
    }
    recover_interrupted(&mut state, &paths, store.read()?.channel.as_str())?;
    let fallback_engine = update::retain_running_binary(&store)?;
    if update::validate_cached(&store, &state.current).is_err() {
        let broken = state.current.clone();
        state.current = state
            .previous
            .take()
            .filter(|a| update::validate_cached(&store, a).is_ok())
            .unwrap_or_else(|| fallback_engine.clone());
        reject(&mut state, &broken, "runtime_identity");
        atomic_json(&journal(&paths), &state)?;
        crate::telemetry::report_update(
            "repair_required",
            store.read()?.channel.as_str(),
            &broken.version,
            &state.current.version,
            "runtime_identity",
        );
    }
    let mut child = launch(&state.current, &paths, &store).ok();
    let mut terminate = Box::pin(super::wait_for_termination());
    let mut poll = tokio::time::interval(Duration::from_secs(3));
    poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut next_check = tokio::time::Instant::now() + Duration::from_secs(5 * 60);
    let mut worker: Option<Child> = None;
    let mut crash_times = std::collections::VecDeque::new();
    let mut next_start = tokio::time::Instant::now();
    let mut parked = false;
    loop {
        tokio::select! {
            _ = &mut terminate => {
                if let Some(child) = &mut child { let _ = stop(child, &paths, &secrets).await; }
                if let Some(worker) = &mut worker { let _ = worker.start_kill(); let _ = worker.wait().await; }
                return Ok(());
            }
            _ = poll.tick() => {}
        }
        let now = tokio::time::Instant::now();
        if worker
            .as_mut()
            .is_some_and(|child| child.try_wait().ok().flatten().is_some())
        {
            worker = None;
            if parked {
                parked = false;
            }
        }
        if now >= next_check {
            next_check = now + Duration::from_secs(60 * 60 + rand::random::<u64>() % 600);
            if worker.is_none() && update::automatic_allowed() && store.read()?.auto_update {
                // Use a retained, verified engine; a broken candidate must not disable repair.
                let executable = if update::validate_cached(&store, &state.current).is_ok() {
                    &state.current.executable
                } else {
                    &fallback_engine.executable
                };
                let mut command = Command::new(executable);
                command
                    .args(["update", "--background", "--json"])
                    .env("INLINE_DATA_DIR", &config.data_dir)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .kill_on_drop(true);
                worker = command.spawn().ok();
            }
        }
        if let Some(status) = child.as_mut().map(Child::try_wait).transpose()?.flatten() {
            child = None;
            if status.success() {
                parked = true;
            } else {
                crash_times.push_back(now);
                while crash_times
                    .front()
                    .is_some_and(|at| now.duration_since(*at) > Duration::from_secs(600))
                {
                    crash_times.pop_front();
                }
                if crash_times.len() >= 3 {
                    if let Some(previous) = state.previous.take() {
                        let failed = state.current.clone();
                        reject(&mut state, &failed, "crash_loop");
                        state.current = previous;
                        atomic_json(&journal(&paths), &state)?;
                        crate::telemetry::report_update(
                            "rolled_back",
                            store.read()?.channel.as_str(),
                            &failed.version,
                            &state.current.version,
                            "crash_loop",
                        );
                    } else {
                        crate::telemetry::report_update(
                            "repair_required",
                            store.read()?.channel.as_str(),
                            &state.current.version,
                            &state.current.version,
                            "crash_loop",
                        );
                    }
                    crash_times.clear();
                }
                next_start = now + Duration::from_secs(10);
            }
        }
        let policy = store.read()?;
        if update::automatic_allowed() && policy.auto_update {
            if let Some(candidate) = policy.staged.filter(|candidate| {
                !state.rejected.contains(&candidate.sha256)
                    && update::newer(&candidate.version, &state.current.version).unwrap_or(false)
            }) {
                let throttled = state
                    .last_activation
                    .is_some_and(|at| unix_now().saturating_sub(at) < 6 * 60 * 60);
                if candidate.minimum_reader_schema_version > state.current.bridge_schema_version {
                    pending(&mut state, Some(&candidate), "maintenance_required", &paths)?;
                } else if !throttled {
                    pending(&mut state, Some(&candidate), "waiting_for_idle", &paths)?;
                    if let Some(current) = &mut child {
                        let ready = service::control_request(
                            &paths,
                            &secrets,
                            ControlCommand::PrepareUpdate,
                        )
                        .await
                        .is_ok_and(|response| {
                            response.status == "update_ready"
                                && Some(response.process_id) == current.id()
                        });
                        // A preference change always wins before stopping a working process.
                        if ready && {
                            let latest = store.read()?;
                            latest.revision == policy.revision && latest.auto_update
                        } {
                            child = activate(
                                &mut state,
                                candidate,
                                Some(current),
                                &paths,
                                &store,
                                &secrets,
                                policy.channel.as_str(),
                                TRIAL,
                            )
                            .await
                            .ok();
                            parked = false;
                            crash_times.clear();
                        } else if ready {
                            let _ = service::control_request(
                                &paths,
                                &secrets,
                                ControlCommand::CancelUpdate,
                            )
                            .await;
                        }
                    } else if !parked {
                        child = activate(
                            &mut state,
                            candidate,
                            None,
                            &paths,
                            &store,
                            &secrets,
                            policy.channel.as_str(),
                            TRIAL,
                        )
                        .await
                        .ok();
                    }
                }
            } else {
                let _ =
                    service::control_request(&paths, &secrets, ControlCommand::CancelUpdate).await;
                if state.candidate.is_some() {
                    pending(&mut state, None, "committed", &paths)?;
                }
            }
        } else {
            let _ = service::control_request(&paths, &secrets, ControlCommand::CancelUpdate).await;
            if state.candidate.is_some() {
                pending(&mut state, None, "committed", &paths)?;
            }
        }
        if child.is_none() && !parked && now >= next_start {
            child = launch(&state.current, &paths, &store).ok();
            next_start = now + Duration::from_secs(30);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    const QUICK: TrialPolicy = TrialPolicy {
        probation: Duration::from_millis(75),
        deadline: Duration::from_secs(1),
        poll: Duration::from_millis(10),
        retry: Duration::from_millis(10),
        stop: Duration::from_millis(100),
    };

    struct Fixture {
        _root: tempfile::TempDir,
        store: Store,
        paths: BridgePaths,
        secrets: super::super::AccountBridgeSecrets,
    }
    impl Fixture {
        fn new() -> Self {
            let root = tempfile::tempdir().unwrap();
            let data = fs::canonicalize(root.path()).unwrap();
            let paths = BridgePaths::from_root(data.join("bridge/accounts/1"), data.join("unused"));
            super::super::ensure_private_dir(&paths.root).unwrap();
            fs::write(&paths.config, b"{}\n").unwrap();
            fs::write(&paths.secrets, b"authentication must survive\n").unwrap();
            let secrets = super::super::AccountBridgeSecrets {
                version: 1,
                owner_user_id: 1,
                control_token: "isolated-fixture".into(),
                owner_auth: None,
                owner_token: String::new(),
                providers: vec![],
            };
            Self {
                store: Store::new(&data),
                _root: root,
                paths,
                secrets,
            }
        }
        fn artifact(&self, behavior: &str) -> Artifact {
            use std::os::unix::fs::PermissionsExt;
            let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
            let script = format!(
                "#!/bin/sh\nexport INLINE_SUPERVISOR_FIXTURE={}\nexport INLINE_SUPERVISOR_FIXTURE_CONFIG={}\nexec {} --exact bridge::update_supervisor::tests::workload_fixture --ignored --nocapture\n",
                quote(behavior),
                quote(self.paths.config.to_str().unwrap()),
                quote(std::env::current_exe().unwrap().to_str().unwrap())
            );
            let temp = self.paths.root.join("fixture");
            fs::write(&temp, script).unwrap();
            let hash = update::file_hash(&temp).unwrap();
            let dir = self.store.root.join("versions").join(&hash);
            crate::update::store::private_dir(&dir).unwrap();
            let executable = dir.join("inline");
            fs::copy(&temp, &executable).unwrap();
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
            Artifact {
                version: env!("CARGO_PKG_VERSION").into(),
                target: "fixture".into(),
                sha256: hash.clone(),
                executable_sha256: hash,
                executable,
                bridge_schema_version: 30,
                minimum_reader_schema_version: 30,
            }
        }
        fn state(&self, current: Artifact) -> Activation {
            Activation {
                schema_version: 1,
                current,
                previous: None,
                candidate: None,
                phase: "committed".into(),
                last_activation: None,
                rejected: vec![],
                failure: None,
            }
        }
        fn assert_account_unchanged(&self) {
            assert_eq!(
                fs::read(&self.paths.secrets).unwrap(),
                b"authentication must survive\n"
            );
            assert_eq!(fs::read(&self.paths.config).unwrap(), b"{}\n");
        }
    }

    // A real isolated child process. This is compiled only into the test
    // executable; production has no fixture mode or verification bypass.
    #[test]
    #[ignore = "subprocess fixture invoked by updater qualification tests"]
    fn workload_fixture() {
        let Ok(behavior) = std::env::var("INLINE_SUPERVISOR_FIXTURE") else {
            return;
        };
        let paths = BridgePaths::for_config_path(Path::new(
            &std::env::var("INLINE_SUPERVISOR_FIXTURE_CONFIG").unwrap(),
        ))
        .unwrap();
        let trace = paths.root.join("trace");
        let append = |line: &str| {
            use std::io::Write;
            let mut f = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&trace)
                .unwrap();
            writeln!(f, "{line}").unwrap();
        };
        append(&format!("start {behavior}"));
        if behavior == "crash" {
            std::process::exit(7);
        }
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            if behavior == "hang" { std::future::pending::<()>().await; }
            let _ = fs::remove_file(&paths.control_socket);
            let listener = tokio::net::UnixListener::bind(&paths.control_socket).unwrap();
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let (read, mut write) = stream.into_split(); let mut read = BufReader::new(read); let mut request = String::new();
                read.read_line(&mut request).await.unwrap();
                let request: serde_json::Value = serde_json::from_str(&request).unwrap();
                let command = request["command"].as_str().unwrap();
                let status = if request["token"] != "isolated-fixture" { "unauthorized" } else if command == "shutdown" { "stopping" } else { "running" };
                let response = serde_json::json!({"version":1,"status":status,"processId":std::process::id(),"inlineConnected":false,"providerReady":false,"detail":null,"cliVersion":env!("CARGO_PKG_VERSION")});
                let mut bytes = serde_json::to_vec(&response).unwrap(); bytes.push(b'\n'); write.write_all(&bytes).await.unwrap(); write.shutdown().await.unwrap();
                if status == "stopping" { append(&format!("stop {behavior}")); let _ = fs::remove_file(&paths.control_socket); break; }
            }
        });
    }

    async fn ready(child: &mut Child, fixture: &Fixture, artifact: &Artifact) {
        local_trial(child, artifact, &fixture.paths, &fixture.secrets, QUICK)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn update_handoff_stops_old_before_starting_candidate_and_commits_only_after_trial() {
        let f = Fixture::new();
        let old = f.artifact("old");
        let candidate = f.artifact("healthy");
        let mut state = f.state(old.clone());
        let mut child = launch(&old, &f.paths, &f.store).unwrap();
        ready(&mut child, &f, &old).await;
        let mut updated = activate(
            &mut state,
            candidate.clone(),
            Some(&mut child),
            &f.paths,
            &f.store,
            &f.secrets,
            "alpha",
            QUICK,
        )
        .await
        .unwrap();
        assert_eq!(state.current, candidate);
        assert_eq!(state.previous, Some(old));
        assert!(state.candidate.is_none());
        assert_eq!(state.phase, "committed");
        assert_eq!(
            fs::read_to_string(f.paths.root.join("trace"))
                .unwrap()
                .lines()
                .take(3)
                .collect::<Vec<_>>(),
            ["start old", "stop old", "start healthy"]
        );
        let saved: Activation = read_json(&journal(&f.paths)).unwrap();
        assert_eq!(saved.current, state.current);
        f.assert_account_unchanged();
        stop_with_timeout(&mut updated, &f.paths, &f.secrets, QUICK.stop)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn update_trial_crashes_and_hangs_restore_working_runtime_without_restoring_old_data() {
        for mode in ["crash", "hang", "cannot_exec"] {
            let f = Fixture::new();
            let old = f.artifact("old");
            let candidate = f.artifact(mode);
            if mode == "cannot_exec" {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&candidate.executable, fs::Permissions::from_mode(0o600))
                    .unwrap();
            }
            let mut state = f.state(old.clone());
            let mut child = launch(&old, &f.paths, &f.store).unwrap();
            ready(&mut child, &f, &old).await;
            // Represents receipts committed since the previous runtime was selected.
            fs::write(f.paths.root.join("live-receipts"), b"new acknowledged work").unwrap();
            let mut restored = activate(
                &mut state,
                candidate.clone(),
                Some(&mut child),
                &f.paths,
                &f.store,
                &f.secrets,
                "alpha",
                QUICK,
            )
            .await
            .unwrap();
            ready(&mut restored, &f, &old).await;
            assert_eq!(state.current, old);
            assert_eq!(state.phase, "rolled_back");
            assert!(state.rejected.contains(&candidate.sha256));
            assert_eq!(
                fs::read(f.paths.root.join("live-receipts")).unwrap(),
                b"new acknowledged work"
            );
            f.assert_account_unchanged();
            stop_with_timeout(&mut restored, &f.paths, &f.secrets, QUICK.stop)
                .await
                .unwrap();
        }
    }

    #[test]
    fn update_reboot_rolls_back_only_uncommitted_trials_and_keeps_pending_work() {
        let f = Fixture::new();
        let old = f.artifact("old");
        let candidate = f.artifact("healthy");
        let mut state = f.state(old.clone());
        pending(&mut state, Some(&candidate), "waiting_for_idle", &f.paths).unwrap();
        recover_interrupted(&mut state, &f.paths, "alpha").unwrap();
        assert_eq!(state.candidate, Some(candidate.clone()));
        state.phase = "trial".into();
        atomic_json(&journal(&f.paths), &state).unwrap();
        let mut rebooted: Activation = read_json(&journal(&f.paths)).unwrap();
        recover_interrupted(&mut rebooted, &f.paths, "alpha").unwrap();
        assert_eq!(rebooted.current, old);
        assert!(rebooted.candidate.is_none());
        assert_eq!(rebooted.failure.as_deref(), Some("interrupted_trial"));
        f.assert_account_unchanged();
    }
}
