//! Persisted failure ledgers that bound bridge restart loops across processes.
//!
//! A provider that keeps failing backs off exponentially up to an hour, and the
//! delay survives service restarts. Configuration failures park the agent (or
//! the whole service) in a needs-setup state instead of retrying at all.

use super::*;

pub(super) const MAX_PROVIDER_BACKOFF: Duration = Duration::from_secs(60 * 60);
/// A restarted provider or service counts as recovered after running this long.
pub(super) const STABLE_AFTER: Duration = Duration::from_secs(60);
const PROVIDER_LEDGER_FILE: &str = "provider-failures.json";
const SERVICE_LEDGER_FILE: &str = "service-failure.json";

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FailureRecord {
    pub(super) consecutive_failures: u32,
    pub(super) last_failure_at: u64,
    pub(super) next_attempt_at: u64,
    pub(super) failure: String,
    #[serde(default)]
    pub(super) needs_setup: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) detail: Option<String>,
}

impl FailureRecord {
    /// Waiting time before the next automatic attempt. A needs-setup record is
    /// re-evaluated once per process start instead of on a timer.
    pub(super) fn retry_delay(&self, now: u64) -> Duration {
        if self.needs_setup {
            return Duration::ZERO;
        }
        Duration::from_secs(self.next_attempt_at.saturating_sub(now)).min(MAX_PROVIDER_BACKOFF)
    }

    /// One-line explanation for status and doctor output.
    pub(super) fn summary(&self, now: u64) -> String {
        let detail = self
            .detail
            .as_deref()
            .map(|detail| format!(": {detail}"))
            .unwrap_or_default();
        if self.needs_setup {
            return format!("needs setup ({}){detail}", self.failure);
        }
        let attempts = match self.consecutive_failures {
            1 => "1 failure".to_string(),
            count => format!("{count} consecutive failures"),
        };
        let delay = self.retry_delay(now);
        let retry = if delay.is_zero() {
            "retry is due".to_string()
        } else {
            format!("next retry in {}", describe_delay(delay))
        };
        format!("{attempts} ({}), {retry}{detail}", self.failure)
    }
}

/// 1 s, 2 s, 4 s, … doubling per consecutive failure, capped at one hour.
pub(super) fn provider_backoff_delay(consecutive_failures: u32) -> Duration {
    if consecutive_failures == 0 {
        return Duration::ZERO;
    }
    let exponent = (consecutive_failures - 1).min(12);
    Duration::from_secs(1_u64 << exponent).min(MAX_PROVIDER_BACKOFF)
}

pub(super) fn next_failure_record(
    previous: Option<&FailureRecord>,
    failure: &str,
    detail: Option<&str>,
    needs_setup: bool,
    now: u64,
) -> FailureRecord {
    let consecutive_failures = previous
        .map(|record| record.consecutive_failures)
        .unwrap_or_default()
        .saturating_add(1);
    let next_attempt_at = if needs_setup {
        now
    } else {
        now.saturating_add(provider_backoff_delay(consecutive_failures).as_secs())
    };
    FailureRecord {
        consecutive_failures,
        last_failure_at: now,
        next_attempt_at,
        failure: failure.to_string(),
        needs_setup,
        detail: detail
            .map(crate::diagnostics::safe_text)
            .filter(|detail| !detail.is_empty()),
    }
}

pub(super) fn describe_delay(delay: Duration) -> String {
    let seconds = delay.as_secs();
    if seconds < 60 {
        format!("{}s", seconds.max(1))
    } else if seconds < 60 * 60 {
        format!("{}m", seconds.div_ceil(60))
    } else {
        format!("{}h", seconds.div_ceil(60 * 60))
    }
}

pub(super) fn unix_now() -> u64 {
    u64::try_from(now_seconds()).unwrap_or_default()
}

/// One JSON record per provider installation or account service. Only the
/// process holding the account instance lock writes it; status reads it.
#[derive(Clone, Debug)]
pub(super) struct FailureLedger {
    path: PathBuf,
}

impl FailureLedger {
    pub(super) fn provider(installation: &ProviderInstallationConfig) -> Self {
        Self {
            path: installation.state_dir.join(PROVIDER_LEDGER_FILE),
        }
    }

    pub(super) fn service(paths: &BridgePaths) -> Self {
        Self {
            path: paths.root.join(SERVICE_LEDGER_FILE),
        }
    }

    pub(super) fn load(&self) -> Option<FailureRecord> {
        read_optional_json(&self.path).ok().flatten()
    }

    pub(super) fn record_failure(
        &self,
        failure: &str,
        detail: Option<&str>,
        now: u64,
    ) -> FailureRecord {
        self.record(failure, detail, false, now)
    }

    pub(super) fn record_needs_setup(
        &self,
        failure: &str,
        detail: &str,
        now: u64,
    ) -> FailureRecord {
        self.record(failure, Some(detail), true, now)
    }

    /// The returned record drives this process even when it cannot be saved.
    fn record(
        &self,
        failure: &str,
        detail: Option<&str>,
        needs_setup: bool,
        now: u64,
    ) -> FailureRecord {
        let record = next_failure_record(self.load().as_ref(), failure, detail, needs_setup, now);
        if let Err(error) = write_private_json(&self.path, &record) {
            eprintln!(
                "Could not save the bridge failure backoff: {}",
                safe_diagnostic(&error.to_string())
            );
        }
        record
    }

    pub(super) fn clear(&self) {
        match fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => eprintln!(
                "Could not clear the bridge failure backoff: {}",
                safe_diagnostic(&error.to_string())
            ),
        }
    }
}

/// An explicit owner action (setup, start, restart) retries immediately.
pub(super) fn clear_account_failure_ledgers(paths: &BridgePaths, account: &AccountBridgeConfig) {
    FailureLedger::service(paths).clear();
    for installation in &account.providers {
        FailureLedger::provider(installation).clear();
    }
}

/// Failures that a restart cannot fix: the configured agent executable or
/// runtime is gone. Returns the owner-facing explanation.
pub(super) fn provider_configuration_problem(
    installation: &ProviderInstallationConfig,
    error: Option<&(dyn std::error::Error + 'static)>,
) -> Option<String> {
    let name = provider_display_name(&installation.provider_id).unwrap_or("agent");
    let missing_executable = !installation.executable.as_os_str().is_empty()
        && !is_executable_file(&installation.executable);
    let missing_runtime = error
        .and_then(|error| error.downcast_ref::<inline_agent_driver_acp::AcpLaunchError>())
        .is_some_and(|error| {
            matches!(
                error,
                inline_agent_driver_acp::AcpLaunchError::ProviderRuntimeUnavailable(_)
                    | inline_agent_driver_acp::AcpLaunchError::InvalidDescriptor(_)
            )
        });
    (missing_executable || missing_runtime).then(|| {
        format!(
            "the configured {name} runtime is missing or no longer executable; run `inline setup {}` again",
            installation.provider_id
        )
    })
}

pub(super) fn provider_setup_required(message: impl Into<String>) -> BridgeSetupRequired {
    BridgeSetupRequired::new("provider_configuration", message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_from_one_second_and_caps_at_one_hour() {
        let delays = (0..=16)
            .map(|failures| provider_backoff_delay(failures).as_secs())
            .collect::<Vec<_>>();
        assert_eq!(
            delays,
            [
                0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 3600, 3600, 3600, 3600
            ]
        );
        assert_eq!(provider_backoff_delay(u32::MAX), MAX_PROVIDER_BACKOFF);
    }

    #[test]
    fn consecutive_failures_accumulate_from_the_persisted_record() {
        let first = next_failure_record(None, "provider_exited", Some("exit 1"), false, 1_000);
        assert_eq!(first.consecutive_failures, 1);
        assert_eq!(first.next_attempt_at, 1_001);
        let mut previous = first;
        for _ in 0..20 {
            previous = next_failure_record(Some(&previous), "provider_exited", None, false, 1_000);
        }
        assert_eq!(previous.consecutive_failures, 21);
        assert_eq!(previous.next_attempt_at, 1_000 + 3_600);
        assert_eq!(previous.retry_delay(1_000), MAX_PROVIDER_BACKOFF);
        assert_eq!(
            previous.retry_delay(1_000 + 3_000),
            Duration::from_secs(600)
        );
        assert_eq!(previous.retry_delay(1_000 + 9_000), Duration::ZERO);
    }

    #[test]
    fn retry_delay_is_bounded_when_the_clock_moves_backwards() {
        let record = next_failure_record(None, "provider_exited", None, false, 1_000_000);
        assert!(record.retry_delay(0) <= MAX_PROVIDER_BACKOFF);
    }

    #[test]
    fn needs_setup_records_do_not_schedule_timed_retries() {
        let record = next_failure_record(
            None,
            "provider_configuration",
            Some("runtime missing"),
            true,
            1_000,
        );
        assert!(record.needs_setup);
        assert_eq!(record.retry_delay(1_000), Duration::ZERO);
        assert!(record.summary(1_000).starts_with("needs setup"));
    }

    #[test]
    fn summaries_explain_the_pending_retry() {
        let record = next_failure_record(None, "provider_exited", Some("exit status: 1"), false, 0);
        let mut record = next_failure_record(Some(&record), "provider_exited", None, false, 0);
        record.next_attempt_at = 600;
        assert_eq!(
            record.summary(0),
            "2 consecutive failures (provider_exited), next retry in 10m"
        );
        assert_eq!(
            record.summary(600),
            "2 consecutive failures (provider_exited), retry is due"
        );
    }

    #[test]
    fn ledger_persists_increments_and_clears() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let ledger = FailureLedger {
            path: directory.path().join(PROVIDER_LEDGER_FILE),
        };
        assert_eq!(ledger.load(), None);
        ledger.record_failure("provider_exited", Some("exit status: 1"), 10);
        let second = ledger.record_failure("provider_exited", None, 20);
        assert_eq!(second.consecutive_failures, 2);
        assert_eq!(ledger.load(), Some(second));
        ledger.clear();
        assert_eq!(ledger.load(), None);
        ledger.clear();
    }

    #[test]
    fn a_corrupt_ledger_restarts_the_count() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join(PROVIDER_LEDGER_FILE);
        fs::write(&path, b"not json").expect("write corrupt ledger");
        let ledger = FailureLedger { path };
        assert_eq!(
            ledger
                .record_failure("provider_exited", None, 5)
                .consecutive_failures,
            1
        );
    }

    #[test]
    fn missing_configured_executables_require_setup() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let (account, _) = crate::bridge::tests::account_fixture();
        let mut installation = account.providers[0].clone();
        installation.provider_id = "claude".to_string();
        installation.executable = directory.path().join("missing-adapter");
        let problem = provider_configuration_problem(&installation, None).expect("setup problem");
        assert!(problem.contains("inline setup claude"));

        let executable = directory.path().join("adapter");
        fs::write(&executable, b"#!/bin/sh\n").expect("write executable");
        set_file_mode(&executable, 0o755).expect("make executable");
        installation.executable = executable.clone();
        assert_eq!(provider_configuration_problem(&installation, None), None);

        set_file_mode(&executable, 0o644).expect("drop executable bit");
        assert!(provider_configuration_problem(&installation, None).is_some());

        let transient = io::Error::other("provider exited with exit status: 1");
        set_file_mode(&executable, 0o755).expect("restore executable bit");
        assert_eq!(
            provider_configuration_problem(&installation, Some(&transient)),
            None
        );
        let runtime = inline_agent_driver_acp::AcpLaunchError::ProviderRuntimeUnavailable(
            directory.path().join("amp"),
        );
        assert!(provider_configuration_problem(&installation, Some(&runtime)).is_some());
    }
}
