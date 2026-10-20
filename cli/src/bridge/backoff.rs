//! Failure classification and persisted backoff for the autonomous bridge.
//!
//! Modeled on how Telegram clients treat errors: only a specific signal that
//! proves a restart cannot help stops retrying, the way only
//! `AUTH_KEY_UNREGISTERED` or `SESSION_REVOKED` sign a Telegram client out. A
//! bare HTTP 401/403 proves nothing: the server also uses them to deny one
//! action (for example `UNAUTHORIZED` for a task the user does not own), so
//! such a rejection is verified with one authenticated `GetMe` probe
//! (`session_probe.rs`) before anything parks. A server-requested wait is
//! honored exactly. Everything else retries with jittered exponential
//! backoff, so the bridge never parks on a guess.
//!
//! | Failure                                                          | Telegram analogue        | Class         | Reaction                               |
//! |------------------------------------------------------------------|--------------------------|---------------|----------------------------------------|
//! | API `SESSION_REVOKED`, `SESSION_EXPIRED`, `USER_DEACTIVATED`;    | `AUTH_KEY_UNREGISTERED`, | `NeedsSetup`  | park; `inline login` or setup heals    |
//! | Inline Protocol close 4401 `session_revoked_confirmed`           | `SESSION_REVOKED`,       |               |                                        |
//! |                                                                  | `USER_DEACTIVATED`       |               |                                        |
//! | Bridge has no usable owner sign-in in its secrets                | `AUTH_KEY_UNREGISTERED`  | `NeedsSetup`  | park; `inline login` or setup heals    |
//! | Bridge config removed, account files unreadable or invalid       | (local install gone)     | `NeedsSetup`  | park; setup heals                      |
//! | Configured agent runtime missing or not executable, or its       | (local install gone)     | `NeedsSetup`  | park that agent; re-probe every 2 min  |
//! | launch configuration invalid                                     |                          |               |                                        |
//! | Bare HTTP 401/403 (`UNAUTHORIZED`, `FORBIDDEN`), other 4401      | `-401`/`-403` on one     | `AuthSuspect` | probe `GetMe` with the same credential;|
//! | closes (`authorization_unavailable`), realtime invalidation      | method                   |               | park only if the probe is explicitly   |
//! | whose transport is unknown                                       |                          |               | revoked, otherwise retry with backoff  |
//! | `RateLimited` with a server delay (420/429, `FLOOD_WAIT_X`,      | `FLOOD_WAIT_X`           | `ServerWait`  | wait exactly that long, at most 1 h    |
//! | `Retry-After`)                                                   |                          |               |                                        |
//! | `Network`, `Timeout`, `Internal`, 5xx, `RateLimited` without a   | `-500`, timeouts         | `Transient`   | jittered exponential backoff           |
//! | delay, `AuthRequired` (not connected, unspecified rejection),    |                          |               |                                        |
//! | protocol mismatch, agent process exits, any unclassified error   |                          |               |                                        |
//!
//! Backoff uses full jitter: attempt *n* waits a uniform 1 s..min(cap, 2^(n-1) s).
//! A local agent caps at 5 minutes: a relaunch costs one process spawn, so
//! twelve tries an hour are cheap, and an agent fixed out of band (login,
//! network) is back within 2.5 minutes on average while messages stay queued.
//! The account service and its Inline connections cap at 3 minutes: launchd and
//! systemd already add 10 s between process starts, and after a server incident
//! a whole fleet returns spread over that window instead of in one wave.
//! Telemetry is separately limited to one event per failure class per day.

use super::*;

/// A restarted provider or service counts as recovered after running this long.
pub(super) const STABLE_AFTER: Duration = Duration::from_secs(60);
/// Parked agents re-check their runtime this often, so installing it heals.
pub(super) const PARKED_REPROBE_INTERVAL: Duration = Duration::from_secs(2 * 60);
/// Bound for a server-requested wait, so a malformed or hostile hint cannot
/// freeze the bridge for longer than an hour.
const MAX_SERVER_WAIT: Duration = Duration::from_secs(60 * 60);
const PROVIDER_LEDGER_FILE: &str = "provider-failures.json";
const SERVICE_LEDGER_FILE: &str = "service-failure.json";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Backoff {
    pub(super) cap: Duration,
}

/// Local agent process failures (launch, exit, restart).
pub(super) const PROVIDER_BACKOFF: Backoff = Backoff {
    cap: Duration::from_secs(5 * 60),
};
/// Service process restarts and Inline connection cycles.
pub(super) const SERVICE_BACKOFF: Backoff = Backoff {
    cap: Duration::from_secs(3 * 60),
};

impl Backoff {
    /// Upper bound for the nth consecutive failure: 1 s doubling to the cap.
    pub(super) fn ceiling(self, consecutive_failures: u32) -> Duration {
        if consecutive_failures == 0 {
            return Duration::ZERO;
        }
        let exponent = (consecutive_failures - 1).min(30);
        Duration::from_secs(1_u64 << exponent).min(self.cap)
    }

    /// Full jitter with a one-second floor: uniform in 1 s..=ceiling.
    pub(super) fn delay(self, consecutive_failures: u32, random: u64) -> Duration {
        let ceiling = self.ceiling(consecutive_failures).as_secs();
        if ceiling <= 1 {
            return Duration::from_secs(ceiling);
        }
        Duration::from_secs(1 + random % ceiling)
    }

    pub(super) fn jittered(self, consecutive_failures: u32) -> Duration {
        self.delay(consecutive_failures, jitter_random())
    }
}

pub(super) fn jitter_random() -> u64 {
    OsRng.next_u64()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FailureClass {
    /// A restart provably cannot help; wait for setup, login or a re-probe.
    NeedsSetup,
    /// An authentication rejection that may deny only one action; verify the
    /// session with a probe before parking, otherwise retry like `Transient`.
    AuthSuspect,
    /// The server named a wait; honor exactly that, without jitter.
    ServerWait(Duration),
    /// Uncertain or transient; retry with jittered backoff.
    Transient,
}

/// Server error names that prove the session itself is gone (`errors.ts`).
fn is_session_invalidated_error_name(name: &str) -> bool {
    matches!(
        name.trim().to_ascii_uppercase().as_str(),
        "SESSION_REVOKED" | "SESSION_EXPIRED" | "USER_DEACTIVATED"
    )
}

/// Classifies by walking the error chain. Unrecognized errors are transient.
pub(super) fn classify_failure(error: &(dyn std::error::Error + 'static)) -> FailureClass {
    let mut current = Some(error);
    while let Some(error) = current {
        if error.downcast_ref::<BridgeSetupRequired>().is_some() {
            return FailureClass::NeedsSetup;
        }
        let backend = error
            .downcast_ref::<inline_client::ClientRequestError>()
            .and_then(|error| match error {
                inline_client::ClientRequestError::Backend(backend) => Some(backend),
                _ => None,
            })
            .or_else(|| error.downcast_ref::<inline_client::BackendError>());
        if let Some(backend) = backend {
            return classify_backend_error(backend);
        }
        if let Some(error) = error.downcast_ref::<inline_sdk::InlineProtocolV3Error>() {
            return if error.is_session_revoked() {
                FailureClass::NeedsSetup
            } else if error.is_authorization_invalidated() {
                FailureClass::AuthSuspect
            } else {
                FailureClass::Transient
            };
        }
        match error.downcast_ref::<inline_sdk::api::ApiError>() {
            Some(inline_sdk::api::ApiError::Api { error, .. })
                if is_session_invalidated_error_name(error) =>
            {
                return FailureClass::NeedsSetup;
            }
            Some(
                inline_sdk::api::ApiError::Api {
                    status: Some(401 | 403),
                    ..
                }
                | inline_sdk::api::ApiError::Status {
                    status: 401 | 403, ..
                },
            ) => return FailureClass::AuthSuspect,
            _ => {}
        }
        if matches!(
            error.downcast_ref::<inline_sdk::realtime::RealtimeError>(),
            Some(inline_sdk::realtime::RealtimeError::AuthenticationInvalidated)
        ) {
            return FailureClass::AuthSuspect;
        }
        current = error.source();
    }
    FailureClass::Transient
}

pub(super) fn classify_backend_error(error: &inline_client::BackendError) -> FailureClass {
    use inline_client::ClientErrorCategory as Category;
    if error.session_invalidated {
        return FailureClass::NeedsSetup;
    }
    match (error.category, error.retry_after_seconds) {
        (Category::AuthExpired | Category::ReloginRequired, _) => FailureClass::AuthSuspect,
        (Category::RateLimited, Some(seconds)) if seconds > 0 => {
            FailureClass::ServerWait(bounded_server_wait(seconds))
        }
        _ => FailureClass::Transient,
    }
}

fn bounded_server_wait(seconds: u64) -> Duration {
    let requested = Duration::from_secs(seconds);
    if requested > MAX_SERVER_WAIT {
        eprintln!(
            "Inline asked the bridge to wait {}; waiting {} instead.",
            describe_delay(requested),
            describe_delay(MAX_SERVER_WAIT)
        );
        return MAX_SERVER_WAIT;
    }
    requested
}

/// What an ambiguous authentication rejection means once a probe answered.
pub(super) fn settle_auth_suspect(probe: SessionProbe) -> FailureClass {
    match probe {
        SessionProbe::Revoked => FailureClass::NeedsSetup,
        SessionProbe::Valid | SessionProbe::Inconclusive => FailureClass::Transient,
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FailureRecord {
    pub(super) consecutive_failures: u32,
    pub(super) last_failure_at: u64,
    pub(super) next_attempt_at: u64,
    /// The scheduled wait, which also bounds the delay if the clock moves back.
    #[serde(default)]
    pub(super) wait_seconds: u64,
    pub(super) failure: String,
    #[serde(default)]
    pub(super) needs_setup: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) detail: Option<String>,
}

impl FailureRecord {
    /// Waiting time before the next automatic attempt. A needs-setup record is
    /// re-evaluated on each process start or re-probe instead of on a timer.
    pub(super) fn retry_delay(&self, now: u64) -> Duration {
        if self.needs_setup {
            return Duration::ZERO;
        }
        Duration::from_secs(
            self.next_attempt_at
                .saturating_sub(now)
                .min(self.wait_seconds),
        )
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

pub(super) fn next_failure_record(
    previous: Option<&FailureRecord>,
    failure: &str,
    detail: Option<&str>,
    class: FailureClass,
    backoff: Backoff,
    now: u64,
    random: u64,
) -> FailureRecord {
    let consecutive_failures = previous
        .map(|record| record.consecutive_failures)
        .unwrap_or_default()
        .saturating_add(1);
    let wait = match class {
        FailureClass::NeedsSetup => Duration::ZERO,
        FailureClass::ServerWait(wait) => wait,
        FailureClass::Transient | FailureClass::AuthSuspect => {
            backoff.delay(consecutive_failures, random)
        }
    };
    FailureRecord {
        consecutive_failures,
        last_failure_at: now,
        next_attempt_at: now.saturating_add(wait.as_secs()),
        wait_seconds: wait.as_secs(),
        failure: failure.to_string(),
        needs_setup: class == FailureClass::NeedsSetup,
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
    backoff: Backoff,
}

impl FailureLedger {
    pub(super) fn provider(installation: &ProviderInstallationConfig) -> Self {
        Self {
            path: installation.state_dir.join(PROVIDER_LEDGER_FILE),
            backoff: PROVIDER_BACKOFF,
        }
    }

    pub(super) fn service(paths: &BridgePaths) -> Self {
        Self {
            path: paths.root.join(SERVICE_LEDGER_FILE),
            backoff: SERVICE_BACKOFF,
        }
    }

    pub(super) fn load(&self) -> Option<FailureRecord> {
        read_optional_json(&self.path).ok().flatten()
    }

    /// Records a failure of the given class. The returned record drives this
    /// process even when it cannot be saved.
    pub(super) fn record(
        &self,
        failure: &str,
        detail: Option<&str>,
        class: FailureClass,
        now: u64,
    ) -> FailureRecord {
        let record = next_failure_record(
            self.load().as_ref(),
            failure,
            detail,
            class,
            self.backoff,
            now,
            jitter_random(),
        );
        if let Err(error) = write_private_json(&self.path, &record) {
            eprintln!(
                "Could not save the bridge failure backoff: {}",
                safe_diagnostic(&error.to_string())
            );
        }
        record
    }

    /// Records an error, classifying it from its type.
    pub(super) fn record_error(
        &self,
        failure: &str,
        error: &(dyn std::error::Error + 'static),
        now: u64,
    ) -> FailureRecord {
        self.record(
            failure,
            Some(&error.to_string()),
            classify_failure(error),
            now,
        )
    }

    pub(super) fn record_needs_setup(
        &self,
        failure: &str,
        detail: &str,
        now: u64,
    ) -> FailureRecord {
        self.record(failure, Some(detail), FailureClass::NeedsSetup, now)
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

/// An explicit owner action (setup, login, start, restart, update) retries
/// immediately.
pub(super) fn clear_account_failure_ledgers(paths: &BridgePaths, account: &AccountBridgeConfig) {
    FailureLedger::service(paths).clear();
    for installation in &account.providers {
        FailureLedger::provider(installation).clear();
    }
}

/// Whether any service or agent ledger currently records a failure.
pub(super) fn account_has_failure_records(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
) -> bool {
    FailureLedger::service(paths).load().is_some()
        || account
            .providers
            .iter()
            .any(|installation| FailureLedger::provider(installation).load().is_some())
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

/// A parked agent's runtime looks launchable again (re-probe).
pub(super) fn provider_runtime_recovered(installation: &ProviderInstallationConfig) -> bool {
    provider_configuration_problem(installation, None).is_none()
        && ProviderLaunch::from_installation(installation).is_ok()
}

/// Agents parked for a missing runtime re-probe; a revoked bot credential
/// waits for setup.
pub(super) const PROVIDER_RUNTIME_SETUP: &str = "provider_configuration";
pub(super) const PROVIDER_CREDENTIAL_SETUP: &str = "bot_credential_revoked";

pub(super) fn provider_setup_required(message: impl Into<String>) -> BridgeSetupRequired {
    BridgeSetupRequired::new(PROVIDER_RUNTIME_SETUP, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_client::ClientErrorCategory as Category;

    fn ledger_at(path: PathBuf) -> FailureLedger {
        FailureLedger {
            path,
            backoff: PROVIDER_BACKOFF,
        }
    }

    #[test]
    fn ceilings_double_from_one_second_to_each_cap() {
        let provider = (0..=12)
            .map(|failures| PROVIDER_BACKOFF.ceiling(failures).as_secs())
            .collect::<Vec<_>>();
        assert_eq!(
            provider,
            [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300, 300]
        );
        let service = (0..=10)
            .map(|failures| SERVICE_BACKOFF.ceiling(failures).as_secs())
            .collect::<Vec<_>>();
        assert_eq!(service, [0, 1, 2, 4, 8, 16, 32, 64, 128, 180, 180]);
        assert_eq!(PROVIDER_BACKOFF.ceiling(u32::MAX), PROVIDER_BACKOFF.cap);
    }

    #[test]
    fn full_jitter_spans_one_second_to_the_ceiling() {
        assert_eq!(PROVIDER_BACKOFF.delay(1, u64::MAX), Duration::from_secs(1));
        for failures in 2..40 {
            let ceiling = PROVIDER_BACKOFF.ceiling(failures);
            assert_eq!(PROVIDER_BACKOFF.delay(failures, 0), Duration::from_secs(1));
            assert_eq!(
                PROVIDER_BACKOFF.delay(failures, ceiling.as_secs() - 1),
                ceiling
            );
            for random in [7, 1_000, u64::MAX] {
                let delay = PROVIDER_BACKOFF.delay(failures, random);
                assert!(delay >= Duration::from_secs(1) && delay <= ceiling);
            }
        }
        let samples = (0..64)
            .map(|_| SERVICE_BACKOFF.jittered(20))
            .collect::<HashSet<_>>();
        assert!(samples.len() > 1, "jitter must spread retries");
    }

    fn backend(category: Category) -> inline_client::BackendError {
        inline_client::BackendError::new(category, "redacted")
    }

    #[test]
    fn only_explicit_revocation_needs_setup() {
        for category in [Category::AuthExpired, Category::ReloginRequired] {
            assert_eq!(
                classify_backend_error(&backend(category).with_session_invalidated()),
                FailureClass::NeedsSetup
            );
            // A bare 401/403 maps to AuthExpired without proof; verify first.
            assert_eq!(
                classify_backend_error(&backend(category)),
                FailureClass::AuthSuspect
            );
        }
        for category in [
            Category::AuthRequired,
            Category::Network,
            Category::Timeout,
            Category::Internal,
            Category::RateLimited,
            Category::ProtocolMismatch,
            Category::PermissionDenied,
            Category::NotFound,
            Category::CommitOutcomeUnknown,
            Category::InvalidInput,
            Category::Unsupported,
            Category::Conflict,
        ] {
            assert_eq!(
                classify_backend_error(&backend(category)),
                FailureClass::Transient,
                "{category:?}"
            );
        }
    }

    #[test]
    fn a_permission_denial_401_does_not_park_but_session_expired_does() {
        let denied = inline_client::ClientRequestError::Backend(backend(Category::AuthExpired));
        assert_eq!(classify_failure(&denied), FailureClass::AuthSuspect);
        assert_ne!(classify_failure(&denied), FailureClass::NeedsSetup);
        let api_denied = inline_sdk::api::ApiError::Api {
            status: Some(401),
            error: "UNAUTHORIZED".to_string(),
            error_code: Some(401),
            description: "not the task's assignee".to_string(),
        };
        assert_eq!(classify_failure(&api_denied), FailureClass::AuthSuspect);
        let forbidden = inline_sdk::api::ApiError::Status {
            status: 403,
            message: "Forbidden".to_string(),
            body: None,
        };
        assert_eq!(classify_failure(&forbidden), FailureClass::AuthSuspect);

        for name in ["SESSION_EXPIRED", "SESSION_REVOKED", "USER_DEACTIVATED"] {
            let expired = inline_sdk::api::ApiError::Api {
                status: Some(401),
                error: name.to_string(),
                error_code: Some(401),
                description: "session".to_string(),
            };
            assert_eq!(
                classify_failure(&expired),
                FailureClass::NeedsSetup,
                "{name}"
            );
        }
        let marked = inline_client::ClientRequestError::Backend(
            backend(Category::AuthExpired).with_session_invalidated(),
        );
        assert_eq!(classify_failure(&marked), FailureClass::NeedsSetup);
    }

    #[test]
    fn only_a_confirmed_inline_protocol_revocation_needs_setup() {
        assert_eq!(
            classify_failure(&inline_sdk::InlineProtocolV3Error::SessionRevoked),
            FailureClass::NeedsSetup
        );
        assert_eq!(
            classify_failure(&inline_sdk::InlineProtocolV3Error::AuthorizationInvalidated),
            FailureClass::AuthSuspect
        );
        assert_eq!(
            classify_failure(&inline_sdk::InlineProtocolV3Error::Closed),
            FailureClass::Transient
        );
        assert_eq!(
            classify_failure(&inline_sdk::realtime::RealtimeError::AuthenticationInvalidated),
            FailureClass::AuthSuspect
        );
    }

    #[test]
    fn an_ambiguous_rejection_parks_only_after_an_explicit_probe_failure() {
        assert_eq!(
            settle_auth_suspect(SessionProbe::Valid),
            FailureClass::Transient
        );
        assert_eq!(
            settle_auth_suspect(SessionProbe::Inconclusive),
            FailureClass::Transient
        );
        assert_eq!(
            settle_auth_suspect(SessionProbe::Revoked),
            FailureClass::NeedsSetup
        );
    }

    #[test]
    fn server_requested_waits_are_honored_exactly_up_to_an_hour() {
        assert_eq!(
            classify_backend_error(&backend(Category::RateLimited).with_retry_after_seconds(23)),
            FailureClass::ServerWait(Duration::from_secs(23))
        );
        assert_eq!(
            classify_backend_error(&backend(Category::RateLimited).with_retry_after_seconds(3_600)),
            FailureClass::ServerWait(Duration::from_secs(3_600))
        );
        assert_eq!(
            classify_backend_error(
                &backend(Category::RateLimited).with_retry_after_seconds(24 * 60 * 60)
            ),
            FailureClass::ServerWait(MAX_SERVER_WAIT)
        );
        assert_eq!(MAX_SERVER_WAIT, Duration::from_secs(60 * 60));
        // A hint on another category does not turn it into a wait.
        assert_eq!(
            classify_backend_error(&backend(Category::Network).with_retry_after_seconds(23)),
            FailureClass::Transient
        );
        let error = inline_client::ClientRequestError::Backend(
            inline_client::BackendError::new(Category::RateLimited, "FLOOD_WAIT_23")
                .with_retry_after_seconds(23),
        );
        assert_eq!(
            classify_failure(&error),
            FailureClass::ServerWait(Duration::from_secs(23))
        );
        let record = next_failure_record(
            None,
            "rate_limited",
            None,
            classify_failure(&error),
            SERVICE_BACKOFF,
            100,
            u64::MAX,
        );
        assert_eq!(record.retry_delay(100), Duration::from_secs(23));
    }

    #[test]
    fn unclassified_and_wrapped_errors_are_transient_or_follow_their_source() {
        assert_eq!(
            classify_failure(&io::Error::other("unknown")),
            FailureClass::Transient
        );
        let revoked = inline_client::ClientRequestError::Backend(
            inline_client::BackendError::new(Category::AuthExpired, "session revoked")
                .with_session_invalidated(),
        );
        assert_eq!(classify_failure(&revoked), FailureClass::NeedsSetup);
        let wrapped = io::Error::other(revoked);
        assert_eq!(classify_failure(&wrapped), FailureClass::Transient);
        let setup = provider_setup_required("runtime missing");
        assert_eq!(classify_failure(&setup), FailureClass::NeedsSetup);
    }

    #[test]
    fn consecutive_failures_accumulate_and_stay_within_the_cap() {
        let mut previous = None;
        for _ in 0..30 {
            let record = next_failure_record(
                previous.as_ref(),
                "provider_exited",
                Some("exit 1"),
                FailureClass::Transient,
                PROVIDER_BACKOFF,
                1_000,
                u64::MAX,
            );
            assert!(record.retry_delay(1_000) <= PROVIDER_BACKOFF.cap);
            previous = Some(record);
        }
        let record = previous.unwrap();
        assert_eq!(record.consecutive_failures, 30);
        assert_eq!(record.retry_delay(1_000 + 10_000), Duration::ZERO);
    }

    #[test]
    fn retry_delay_is_bounded_when_the_clock_moves_backwards() {
        let record = next_failure_record(
            None,
            "provider_exited",
            None,
            FailureClass::Transient,
            PROVIDER_BACKOFF,
            1_000_000,
            0,
        );
        assert!(record.retry_delay(0) <= Duration::from_secs(record.wait_seconds));
    }

    #[test]
    fn needs_setup_records_do_not_schedule_timed_retries() {
        let record = next_failure_record(
            None,
            PROVIDER_RUNTIME_SETUP,
            Some("runtime missing"),
            FailureClass::NeedsSetup,
            PROVIDER_BACKOFF,
            1_000,
            0,
        );
        assert!(record.needs_setup);
        assert_eq!(record.retry_delay(1_000), Duration::ZERO);
        assert!(record.summary(1_000).starts_with("needs setup"));
    }

    #[test]
    fn summaries_explain_the_pending_retry() {
        let mut record = next_failure_record(
            None,
            "provider_exited",
            None,
            FailureClass::ServerWait(Duration::from_secs(600)),
            PROVIDER_BACKOFF,
            0,
            0,
        );
        record.consecutive_failures = 2;
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
        let ledger = ledger_at(directory.path().join(PROVIDER_LEDGER_FILE));
        assert_eq!(ledger.load(), None);
        ledger.record_error("provider_exited", &io::Error::other("exit status: 1"), 10);
        let second = ledger.record("provider_exited", None, FailureClass::Transient, 20);
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
        let ledger = ledger_at(path);
        assert_eq!(
            ledger
                .record("provider_exited", None, FailureClass::Transient, 5)
                .consecutive_failures,
            1
        );
    }

    #[test]
    fn missing_configured_executables_require_setup_and_recover_on_reprobe() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let (account, _) = crate::bridge::tests::account_fixture();
        let mut installation = account.providers[0].clone();
        installation.executable = directory.path().join("missing-codex");
        let problem = provider_configuration_problem(&installation, None).expect("setup problem");
        assert!(problem.contains("inline setup codex"));
        assert!(!provider_runtime_recovered(&installation));

        let executable = directory.path().join("codex");
        fs::write(&executable, b"#!/bin/sh\n").expect("write executable");
        set_file_mode(&executable, 0o755).expect("make executable");
        installation.executable = executable.clone();
        assert_eq!(provider_configuration_problem(&installation, None), None);
        assert!(provider_runtime_recovered(&installation));

        set_file_mode(&executable, 0o644).expect("drop executable bit");
        assert!(provider_configuration_problem(&installation, None).is_some());
        assert!(!provider_runtime_recovered(&installation));

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
