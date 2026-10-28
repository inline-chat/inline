use std::collections::{HashMap, HashSet};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::StreamExt;
use inline_agent_bridge::{
    Acknowledgement, ActivityDetail, ActivityDetailStyle, ActivitySemanticKind, ActivityStatus,
    ActivityTextStream, ActivityUpsert, AddressSignals, Addressing, AgentDriver, AgentEvent,
    AgentMessagePhase, AgentMessageUpdate, ApprovalClaimContext, ApprovalClaimOutcome,
    ApprovalDecision, ApprovalOption, ApprovalRecord, BindingKey, BridgeStore, ChatSettingsField,
    ChatSettingsRecord, CommandChoiceAction, CommandChoiceClaimContext, CommandChoiceClaimOutcome,
    CommandChoiceRequest, CommandInvocation, CoordinatorEffect, Direction, DirectionDisposition,
    DirectionId, DriverError, DriverSettingsCatalog, FileChange, HistoryImportState, HostToolCall,
    HostToolCallClaim, HostToolCallRecord, HostToolConfiguration, HostToolHandler, HostToolResult,
    HostToolSpec, HostToolTransport, InboundEnvelope, InboundRecord, InboundState,
    InboundUndoOutcome, InstallationId, InstallationRecord, MAX_RECENT_WORKSPACES,
    MAX_SESSION_PICKER_ITEMS, OperatorAllowlistClaimContext, OperatorAllowlistClaimOutcome,
    OperatorAllowlistDecision, OperatorPolicy, OutputAttachment, OutputAttachmentKind,
    PendingApproval, PendingCommandChoiceRequest, PendingOperatorAllowlistRequest, PendingQuestion,
    PendingSessionPicker, PlanStep, PlanStepStatus, ProviderId, ProviderSessionManager, Question,
    QuestionAnswer, QuestionClaimContext, QuestionClaimLocator, QuestionClaimOutcome,
    QuestionRequest, QuestionResolution, QuestionState, QueueItemId, ReplyThreadMode,
    ReplyThreadOverrideUpdateOutcome, SESSION_PICKER_PAGE_SIZE, SessionManagerError,
    SessionPickerAction, SessionPickerClaimContext, SessionPickerClaimOutcome,
    SessionPickerCompletion, SessionPickerRecord, SessionPickerState, SessionPickerThreadGate,
    SettingsUpdateOutcome, SteeringSupport, StoreError, StreamingPresenter, TriggerDecision,
    TriggerResolver, TurnContext, TurnCoordinator, TurnInput, TurnOptions, TurnOutcome, TurnTiming,
    UpdatePriority, ValidationSummary, VisibilityMode, WORKING_CONTINUED_STATUS, WORKING_STATUS,
    WorkspaceChoice, WorkspaceId, WorkspaceRecord, format_elapsed_compact, parse_command,
    reap_stale_process_host, sanitize_visible_command, sanitize_visible_transcript,
};
use inline_client::{
    AgentConfigurationCatalog, AgentModelCatalog, AgentModelOption, AgentProjectCatalog,
    AgentProjectOption, AgentReasoningCatalog, AgentReasoningEffortOption,
    AgentThreadConfiguration, AgentThreadContext, AnswerBotChatSettingsRequest, AuthCredential,
    AuthToken, BotCapability, BotCapabilityKind, BotChatSettingsControl, BotChatSettingsDocument,
    BotChatSettingsFolder, BotChatSettingsFolderOption, BotChatSettingsInfoTone,
    BotChatSettingsItem, BotChatSettingsProblem, BotChatSettingsProblemCode,
    BotChatSettingsResponse, BotChatSettingsSection, BotChatSettingsSelectOption,
    BotInteractionEvent, BotSettingsValue, ClientErrorCategory, ClientEvent, ClientIdentity,
    ClientRequestError, ClientStore, ConnectRequest, CreateReplyThreadRequest, DialogFollowMode,
    DialogRecord, DialogsOrder, DialogsRequest, EditInteractiveMessageRequest, EditMessageRequest,
    ExternalId, HistoryRequest, InlineClient, InlineId, LosslessEventDelivery, MediaKind,
    MessageActionButton, MessageActionKind, MessageActionRow, MessageActions, MessageContent,
    MessageRecord, PeerRef, RandomId, ReactRequest, SdkBackend, SendInteractiveTextRequest,
    SendNotificationMode, SendTextRequest, SqliteStore, TypingRequest, UploadRequest,
    UploadThumbnail,
};
use inline_protocol::proto;
use inline_sdk::RealtimeClient;
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::config::Config;
use crate::errors::{BridgeAlreadyRunning, BridgeSetupRequired, CliError, ReportedCliFailure};
use crate::identity::connect_realtime;
use crate::output::{self, JsonFormat};
use crate::state::LocalDb;

mod adapter;
mod allowlist_ui;
mod approval_ui;
mod copy;
mod inline_tools;
mod provider;
mod question_ui;
mod reply_threads;
mod service;
mod stream_ui;
mod supervisor;
// Bridge v2 runtime pieces; wired in behind the per-provider flag.
#[allow(dead_code)]
mod v2;
use allowlist_ui::*;
use approval_ui::*;
use copy::{BridgeNotice, failure_message, session_open_notice};
use inline_tools::*;
pub(crate) use provider::bridge_provider_setup_descriptors;
use provider::*;
use question_ui::*;
use reply_threads::*;
use stream_ui::*;
use supervisor::{
    ProviderConnectionLease, ProviderReadiness, ProviderSupervisor, ResponsiveProviderLaunch,
    launch_provider_responsively, shutdown_requested,
};
mod recovery;
use recovery::*;
mod user_config;
pub(crate) use user_config::{
    AgentSetupInstallation, agent_setup_installation, upsert_agent_setup_installation,
};
pub use user_config::{OperatorMutation, operators_list, operators_mutate};
use user_config::{
    ReplyThreadDefault, ReplyThreadDefaultSource, add_operator_for_provider,
    ensure_operator_user_config, operator_policy_for_provider, reply_thread_default_for_provider,
    set_provider_operator_ids,
};

const INSTALLATION_ID: &str = "codex";
const PROVIDER_ID: &str = "codex";
const LEGACY_CONFIG_VERSION: u32 = 3;
const ACCOUNT_CONFIG_VERSION: u32 = 4;
const ACCOUNT_SECRETS_VERSION: u32 = 2;
const SCHEDULING_SCAN_BATCH_SIZE: usize = 64;
const TURN_LANE_PROMOTION_QUEUE_CAPACITY: usize = 32;
// Interactive settings should fail fast, but a cold Claude session can need
// longer than that to publish the model catalog during service startup.
const INITIAL_PROVIDER_CATALOG_DEADLINE: Duration = Duration::from_secs(15);

mod account;
use account::*;
mod commands;
use commands::*;
mod claude_history;
use claude_history::*;
mod session_browser;
use session_browser::*;
mod filesystem;
mod settings;
use settings::*;
mod owner_control;
mod projects;
use owner_control::{
    OwnerConnectionEnd, OwnerControl, owner_control_error_invalidates_authentication,
};
mod workspace_rpc;
use workspace_rpc::*;
mod routing;
use routing::*;
mod context;
use context::*;
mod text_links;
use text_links::*;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum CallbackDecision {
    Option { index: usize },
}

#[derive(Debug, Serialize, Deserialize)]
struct ApprovalCallback {
    version: u32,
    token: String,
    decision: CallbackDecision,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum QuestionCallbackChoice {
    Option { index: usize },
    Other,
    Skip,
}

#[derive(Debug, Serialize, Deserialize)]
struct QuestionCallback {
    version: u32,
    token: String,
    choice: QuestionCallbackChoice,
}

#[derive(Debug, Serialize, Deserialize)]
struct QueueUndoCallback {
    version: u32,
    event_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SettingsCommandChoiceCallbackAction {
    Select { value: String },
    Page { page: i64 },
    Cancel,
}

#[derive(Debug, Serialize, Deserialize)]
struct SettingsCommandChoiceCallback {
    version: u32,
    token: String,
    action: SettingsCommandChoiceCallbackAction,
}

mod dev;
pub use dev::{
    DebugSettingsRequest, debug_observe_typing, debug_probe_workspace_picker,
    debug_request_settings, run_codex_dev,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SetupOutput {
    status: &'static str,
    provider: &'static str,
    provider_version: String,
    display_name: String,
    bot_username: String,
    workspace: String,
    background_service: String,
}

pub(crate) struct ProviderSetupOutcome {
    pub(crate) provider: &'static str,
    pub(crate) provider_version: String,
    pub(crate) installation_id: String,
    pub(crate) bot_user_id: i64,
    pub(crate) bot_username: String,
    pub(crate) display_name: String,
    pub(crate) workspace: PathBuf,
    pub(crate) background_service: String,
}

pub(crate) struct ProviderSetupOptions {
    pub(crate) quiet_adapter_install: bool,
    pub(crate) allow_adapter_install: bool,
    pub(crate) manage_service: bool,
    pub(crate) operator_user_ids: Option<Vec<i64>>,
}

pub(crate) enum ProviderSetupProgress {
    Started(&'static str),
    Completed(&'static str, &'static str),
}

pub async fn setup_provider(
    config: &Config,
    owner_auth: AuthCredential,
    provider_id: &str,
    folder: Option<PathBuf>,
    name: Option<String>,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let outcome = setup_provider_core(
        config,
        owner_auth,
        provider_id,
        folder,
        name,
        ProviderSetupOptions {
            quiet_adapter_install: json,
            allow_adapter_install: true,
            manage_service: true,
            operator_user_ids: None,
        },
    )
    .await?;
    let result = SetupOutput {
        status: "ready",
        provider: outcome.provider,
        provider_version: outcome.provider_version,
        display_name: outcome.display_name,
        bot_username: outcome.bot_username,
        workspace: outcome.workspace.display().to_string(),
        background_service: outcome.background_service,
    };
    if json {
        output::print_json(&result, json_format)?;
    } else {
        println!("{} is ready in Inline.", result.display_name);
        if result.provider != "codex" {
            println!(
                "Experimental provider: {} is not part of the Codex-only external beta.",
                result.provider
            );
        } else if !cfg!(target_os = "macos") {
            println!(
                "Experimental platform: the Codex external beta is currently certified only on macOS."
            );
        }
        println!(
            "Provider: {} ({})",
            result.provider, result.provider_version
        );
        println!("Workspace: {}", workspace_label(&outcome.workspace));
        println!("Background service: {}", result.background_service);
    }
    Ok(())
}

pub(crate) async fn setup_provider_core(
    config: &Config,
    owner_auth: AuthCredential,
    provider_id: &str,
    folder: Option<PathBuf>,
    name: Option<String>,
    options: ProviderSetupOptions,
) -> Result<ProviderSetupOutcome, Box<dyn std::error::Error>> {
    setup_provider_core_with_progress(
        config,
        owner_auth,
        provider_id,
        folder,
        name,
        options,
        |_| {},
    )
    .await
}

pub(crate) fn preflight_claude_setup(
    allow_adapter_install: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    provider::preflight_claude_setup(allow_adapter_install)
        .map_err(|error| CliError::provider_integration_failed(error).into())
}

pub(crate) async fn setup_provider_core_with_progress<F>(
    config: &Config,
    owner_auth: AuthCredential,
    provider_id: &str,
    folder: Option<PathBuf>,
    name: Option<String>,
    options: ProviderSetupOptions,
    mut progress: F,
) -> Result<ProviderSetupOutcome, Box<dyn std::error::Error>>
where
    F: FnMut(ProviderSetupProgress),
{
    progress(ProviderSetupProgress::Started("preflight"));
    let workspace = resolve_setup_workspace(folder)?;
    let mut owner = crate::owner_session::OwnerSession::connect(config, owner_auth).await?;
    let me = owner
        .call(proto::GetMeInput {})
        .await?
        .user
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "GetMe returned no user"))?;
    if me.id <= 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "owner id is invalid").into());
    }
    let account_paths = BridgePaths::for_owner(config, me.id);
    progress(ProviderSetupProgress::Completed("preflight", "ready"));

    progress(ProviderSetupProgress::Started("integration"));
    let provider = prepare_setup_provider(
        &account_paths,
        provider_id,
        options.quiet_adapter_install,
        options.allow_adapter_install,
    )
    .await
    .map_err(CliError::provider_integration_failed)?;
    progress(ProviderSetupProgress::Completed("integration", "ready"));

    progress(ProviderSetupProgress::Started("bot"));
    let provisioned = provision_dev_bot(
        config,
        &mut owner,
        me,
        &provider,
        &workspace,
        name.as_deref(),
    )
    .await?;
    progress(ProviderSetupProgress::Completed("bot", "configured"));

    progress(ProviderSetupProgress::Started("access"));
    validate_account(&provisioned.account, &provisioned.secrets)?;
    if let Some(operator_user_ids) = options.operator_user_ids.as_deref() {
        set_provider_operator_ids(&provisioned.account, provider_id, operator_user_ids)?;
    }
    progress(ProviderSetupProgress::Completed("access", "configured"));

    progress(ProviderSetupProgress::Started("service"));
    let background_service = if options.manage_service {
        service::install_service(&provisioned.paths, &provisioned.account)?;
        service::start_service(
            &provisioned.paths,
            &provisioned.account,
            &provisioned.secrets,
        )
        .await?;
        progress(ProviderSetupProgress::Completed("service", "started"));
        progress(ProviderSetupProgress::Started("verification"));
        let status = service::wait_for_provider_ready(
            &provisioned.paths,
            &provisioned.account,
            &provisioned.installation,
            &provisioned.secrets,
        )
        .await?
        .status;
        progress(ProviderSetupProgress::Completed("verification", "ready"));
        status
    } else {
        progress(ProviderSetupProgress::Completed("service", "skipped"));
        progress(ProviderSetupProgress::Started("verification"));
        progress(ProviderSetupProgress::Completed(
            "verification",
            "action_required",
        ));
        "restart_required".to_string()
    };
    Ok(ProviderSetupOutcome {
        provider: provider.provider_id,
        provider_version: provider.version,
        installation_id: provisioned.installation.installation_id.clone(),
        bot_user_id: provisioned.installation.bot_user_id,
        bot_username: provisioned.installation.bot_username.clone(),
        display_name: provisioned.installation.display_name.clone(),
        workspace: provisioned.installation.workspace.clone(),
        background_service,
    })
}

fn install_bridge_logger(trace: bool) {
    let level = if trace {
        log::LevelFilter::Trace
    } else {
        log::LevelFilter::Warn
    };
    let mut logger = env_logger::Builder::new();
    logger
        // Never inherit an ambient broad filter: dependency traces can contain
        // request URLs or payload details. Only bridge-owned metadata targets
        // participate in this diagnostic stream.
        .filter_level(log::LevelFilter::Off)
        .filter_module("inline::bridge", level)
        .filter_module("inline_agent_bridge", level)
        .filter_module("inline_agent_driver_codex", level)
        .filter_module("inline_agent_driver_acp", level)
        .format_timestamp_millis()
        .write_style(env_logger::WriteStyle::Never);
    let _ = logger.try_init();
}

/// How often a standby service retries the account lock held by another process.
const INSTANCE_LOCK_STANDBY_POLL: Duration = Duration::from_secs(2);
/// How often a running agent re-reads its operator allowlist.
const POLICY_RELOAD_INTERVAL: Duration = Duration::from_secs(30);

/// Runs the account service under launchd/systemd. Both restart a failed exit
/// every ten seconds, so failures that a restart cannot fix end successfully:
/// a duplicate waits on standby for the lock, and missing setup is recorded for
/// `inline bridge status`/`doctor` before a clean exit.
pub async fn run_service(
    config_path: PathBuf,
    trace: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let config_path = match fs::canonicalize(&config_path) {
        Ok(config_path) => config_path,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            stop_service_for_setup(
                None,
                &BridgeSetupRequired::new(
                    "config_missing",
                    "the bridge configuration was removed; run Inline agent setup again",
                ),
            );
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let paths = BridgePaths::for_config_path(&config_path)?;
    // Own the account before reading its files or touching shared logs.
    let Some(_instance_lock) = wait_for_instance_lock(&paths.instance_lock).await? else {
        return Ok(());
    };
    // The service manager restarts a failed exit every ten seconds; keep the
    // persisted backoff for repeated failures it cannot see.
    let service_ledger = FailureLedger::service(&paths);
    let pending_delay = service_ledger
        .load()
        .map(|record| record.retry_delay(unix_now()))
        .unwrap_or_default();
    if !pending_delay.is_zero() {
        eprintln!(
            "The bridge service failed repeatedly; waiting {} before starting again.",
            describe_delay(pending_delay)
        );
        let mut termination = Box::pin(wait_for_termination());
        tokio::select! {
            _ = tokio::time::sleep(pending_delay) => {}
            _ = &mut termination => return Ok(()),
        }
    }
    match run_owned_service(&paths, trace).await {
        Ok(()) => {
            service_ledger.clear();
            Ok(())
        }
        Err(error) => {
            let setup = match error.downcast_ref::<BridgeSetupRequired>() {
                Some(setup) => Some(BridgeSetupRequired::new(
                    setup.reason,
                    setup.message.clone(),
                )),
                None => match classify_failure(error.as_ref()) {
                    // An explicit revocation that surfaced from an owner request.
                    FailureClass::NeedsSetup => owner_sign_in_expired(&paths),
                    // A bare 401/403 from an owner request: verify the session
                    // before stopping; otherwise restart with backoff.
                    FailureClass::AuthSuspect
                        if probe_owner_session(&paths).await == SessionProbe::Revoked =>
                    {
                        owner_sign_in_expired(&paths)
                    }
                    _ => None,
                },
            };
            if let Some(setup) = setup {
                stop_service_for_setup(Some(&paths), &setup);
                return Ok(());
            }
            // Transient or unclassified: exit for the service manager to
            // restart, then wait out the persisted, jittered backoff.
            let failure = crate::errors::json_cli_error_from_error(error.as_ref()).code;
            service_ledger.record_error(&failure, error.as_ref(), unix_now());
            Err(error)
        }
    }
}

/// Explains why an agent is parked, and whether a re-probe can heal it.
fn provider_park_reason(
    installation: &ProviderInstallationConfig,
    error: &(dyn std::error::Error + 'static),
) -> (&'static str, String) {
    match error.downcast_ref::<BridgeSetupRequired>() {
        Some(setup) => (setup.reason, setup.message.clone()),
        None => (
            PROVIDER_CREDENTIAL_SETUP,
            format!(
                "Inline signed out the bot for this agent; run `inline setup {}` again",
                installation.provider_id
            ),
        ),
    }
}

/// Holds a parked agent until shutdown (false) or, for a missing runtime,
/// until a periodic re-probe finds it launchable again (true).
async fn park_until_runtime_recovers(
    installation: &ProviderInstallationConfig,
    reason: &str,
    reprobe_interval: Duration,
    shutdown: &mut Option<tokio::sync::watch::Receiver<bool>>,
) -> bool {
    loop {
        tokio::select! {
            _ = wait_for_control_shutdown(shutdown) => return false,
            _ = tokio::time::sleep(reprobe_interval) => {
                if reason == PROVIDER_RUNTIME_SETUP && provider_runtime_recovered(installation) {
                    return true;
                }
            }
        }
    }
}

/// Waits quietly while another bridge process serves this account, then takes
/// over. Returns `None` when the service is asked to stop while waiting.
async fn wait_for_instance_lock(path: &Path) -> io::Result<Option<fs::File>> {
    if let Some(lock) = try_acquire_instance_lock(path)? {
        return Ok(Some(lock));
    }
    eprintln!(
        "Another Inline bridge process already serves this account; waiting on standby until it stops."
    );
    let mut termination = Box::pin(wait_for_termination());
    loop {
        tokio::select! {
            _ = tokio::time::sleep(INSTANCE_LOCK_STANDBY_POLL) => {}
            _ = &mut termination => return Ok(None),
        }
        if let Some(lock) = try_acquire_instance_lock(path)? {
            eprintln!("The other bridge process stopped; this service now serves the account.");
            return Ok(Some(lock));
        }
    }
}

fn stop_service_for_setup(paths: Option<&BridgePaths>, setup: &BridgeSetupRequired) {
    if let Some(paths) = paths {
        FailureLedger::service(paths).record_needs_setup(setup.reason, &setup.message, unix_now());
    }
    eprintln!(
        "Inline bridge stopped until setup runs again: {}",
        safe_diagnostic(&setup.message)
    );
    crate::telemetry::report_bridge_setup_required("service", setup.reason);
}

fn service_setup_required(
    reason: &'static str,
    message: &str,
    error: Box<dyn std::error::Error>,
) -> Box<dyn std::error::Error> {
    BridgeSetupRequired::new(
        reason,
        format!("{message}: {}", safe_diagnostic(&error.to_string())),
    )
    .into()
}

const OWNER_SIGN_IN_EXPIRED: &str =
    "the Inline sign-in used by this bridge expired; run Inline agent setup again";

/// Runtime configuration for the account, independent of the CLI's own.
fn account_runtime_config(paths: &BridgePaths, account: &AccountBridgeConfig) -> Config {
    Config {
        api_base_url: account.api_base_url.clone(),
        realtime_url: account.realtime_url.clone(),
        secrets_path: paths.root.join("owner-secrets-unused.json"),
        state_path: paths.root.join("owner-state-unused.json"),
        data_dir: paths.root.clone(),
        release_manifest_url: None,
        release_install_url: None,
    }
}

/// Probes the bridge's stored owner sign-in; inconclusive when unreadable.
async fn probe_owner_session(paths: &BridgePaths) -> SessionProbe {
    let Ok((account, secrets)) = load_account_files(paths) else {
        return SessionProbe::Inconclusive;
    };
    let Ok(owner_auth) = owner_credential(&secrets) else {
        return SessionProbe::Inconclusive;
    };
    probe_session(&account_runtime_config(paths, &account), &owner_auth).await
}

/// Clears the revoked owner sign-in so `inline login` can replace it.
fn owner_sign_in_expired(paths: &BridgePaths) -> Option<BridgeSetupRequired> {
    if let Ok((_, secrets)) = load_account_files(paths)
        && let Ok(owner_auth) = owner_credential(&secrets)
        && let Err(error) = clear_bridge_owner_authority(paths, &owner_auth)
    {
        eprintln!(
            "Could not clear the revoked bridge sign-in: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    Some(BridgeSetupRequired::new(
        "owner_credential_expired",
        OWNER_SIGN_IN_EXPIRED,
    ))
}

/// The owner client stops listening once it reports an authentication
/// failure. A probe decides whether the session is gone; in every other case
/// the connection must be rebuilt from the bridge's own secrets, exactly like
/// a lost connection. Continuing would leave a healthy-looking service whose
/// owner connection never receives anything again.
fn owner_end_after_probe(probe: SessionProbe) -> OwnerConnectionEnd {
    match probe {
        SessionProbe::Revoked => OwnerConnectionEnd::Revoked,
        SessionProbe::Valid | SessionProbe::Inconclusive => OwnerConnectionEnd::Lost,
    }
}

/// Ends the service so the service manager restarts it; the persisted,
/// jittered service backoff paces the reconnect.
fn owner_connection_lost_error() -> Box<dyn std::error::Error> {
    io::Error::new(
        io::ErrorKind::ConnectionAborted,
        "the owner connection stopped receiving; restarting the bridge",
    )
    .into()
}

async fn run_owned_service(
    paths: &BridgePaths,
    trace: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let paths = paths.clone();
    let (mut account, secrets) = load_account_files(&paths).map_err(|error| {
        service_setup_required(
            "account_unreadable",
            "the bridge account files could not be read",
            error,
        )
    })?;
    validate_account(&account, &secrets).map_err(|error| {
        service_setup_required("account_invalid", "the bridge account is incomplete", error)
    })?;
    let runtime_config = account_runtime_config(&paths, &account);
    service::install_runtime_logging(&paths)?;
    install_bridge_logger(trace);
    eprintln!(
        "Inline bridge service starting version={} os={} arch={}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH
    );
    log::info!(
        target: "inline::bridge::trace",
        "trace_schema=1 phase=service_start metadata_only=true"
    );
    let owner_control_seed_required = !account.owner_control_cursor_seeded;
    let owner_auth = owner_credential(&secrets).map_err(|_| {
        BridgeSetupRequired::new(
            "owner_credential_missing",
            "this bridge has no usable Inline sign-in; run Inline agent setup again",
        )
    })?;
    let mut owner_connection_failures = 0_u32;
    let owner_control = loop {
        match OwnerControl::connect(
            &runtime_config,
            &paths,
            account.owner_user_id,
            &owner_auth,
            owner_control_seed_required,
        )
        .await
        {
            Ok(control) => {
                if owner_control_seed_required {
                    account.owner_control_cursor_seeded = true;
                    let _account_mutation_lock = acquire_account_mutation_lock(&paths)?;
                    let mut latest: AccountBridgeConfig = read_required_json(&paths.config)?;
                    latest.owner_control_cursor_seeded = true;
                    write_private_json(&paths.config, &latest)?;
                }
                break Some(Arc::new(control));
            }
            Err(error) => {
                let class = match classify_failure(error.as_ref()) {
                    FailureClass::AuthSuspect => {
                        settle_auth_suspect(probe_session(&runtime_config, &owner_auth).await)
                    }
                    class => class,
                };
                if class == FailureClass::NeedsSetup {
                    let _ = clear_bridge_owner_authority(&paths, &owner_auth)?;
                    return Err(BridgeSetupRequired::new(
                        "owner_credential_expired",
                        OWNER_SIGN_IN_EXPIRED,
                    )
                    .into());
                }
                // Anything short of an explicit revocation keeps retrying here.
                owner_connection_failures = owner_connection_failures.saturating_add(1);
                crate::telemetry::report_bridge_runtime_error(
                    "owner",
                    "owner_startup",
                    error.as_ref(),
                    Some(owner_connection_failures),
                );
                let delay = match class {
                    FailureClass::ServerWait(wait) => wait,
                    _ => SERVICE_BACKOFF.jittered(owner_connection_failures),
                };
                eprintln!(
                    "Owner connection unavailable; bridge will retry in {}: {}",
                    describe_delay(delay),
                    safe_diagnostic(&error.to_string())
                );
                tokio::time::sleep(delay).await;
            }
        }
    };
    // The service owns a working sign-in again; forget any earlier setup stop.
    // Other failures are forgiven only after the service stays up.
    let service_ledger = FailureLedger::service(&paths);
    let mut service_recovery_pending = match service_ledger.load() {
        Some(record) if record.needs_setup => {
            service_ledger.clear();
            false
        }
        record => record.is_some(),
    };
    let mut service_stable = Box::pin(tokio::time::sleep(STABLE_AFTER));
    let mut owner_connection_end = owner_control
        .as_ref()
        .and_then(|control| control.take_connection_end_receiver());
    reconcile_owner_dm_chat_ids(
        &paths,
        &mut account,
        &secrets,
        owner_control
            .as_deref()
            .expect("connected service owner control"),
    )
    .await?;
    let health = service::RuntimeHealth::starting(
        account
            .providers
            .iter()
            .map(|provider| provider.installation_id.clone()),
    );
    let provider_readiness = ProviderReadiness::new(health.clone());
    let control_server = service::ControlServer::bind(
        &paths.control_socket,
        secrets.control_token.clone(),
        health.clone(),
    )
    .await?;
    let workspace_registrar = match WorkspaceRegistrar::bind(&paths, account.clone()).await {
        Ok(registrar) => registrar,
        Err(error) => {
            eprintln!(
                "Host-local folder picker is unavailable: {}",
                safe_diagnostic(&error.to_string())
            );
            None
        }
    };
    let workspace_picker = workspace_registrar
        .as_ref()
        .map(WorkspaceRegistrar::endpoint);
    let mut control_shutdown = Some(control_server.shutdown_receiver());
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let manifest_write = Arc::new(tokio::sync::Mutex::new(()));
    let provider_probe_capacity = Arc::new(tokio::sync::Semaphore::new(1));
    let mut termination = Box::pin(wait_for_termination());
    let mut providers = futures_util::stream::FuturesUnordered::new();
    let mut supervisor = ProviderSupervisor::new(
        account
            .providers
            .iter()
            .map(|provider| provider.installation_id.clone()),
    );

    for installation in account.providers.iter().cloned() {
        let credentials = provider_credentials(&secrets, &installation)?.clone();
        let provider_config = runtime_config.clone();
        let provider_paths = paths.clone();
        let provider_account = account.clone();
        let provider_shutdown = shutdown_rx.clone();
        let provider_owner_control = owner_control.clone();
        let provider_manifest_write = manifest_write.clone();
        let provider_probe_capacity = provider_probe_capacity.clone();
        let provider_readiness = provider_readiness.clone();
        let provider_workspace_picker = workspace_picker.clone();
        let installation_id = installation.installation_id.clone();
        let provider_name = installation.display_name.clone();
        providers.push(Box::pin(async move {
            let mut failures = 0_u32;
            let result: Result<(), Box<dyn std::error::Error>> = loop {
                if *provider_shutdown.borrow() {
                    break Ok(());
                }
                let cycle_started = tokio::time::Instant::now();
                let result = run_provider_installation(
                    &provider_config,
                    installation.clone(),
                    ProviderRuntimeContext {
                        paths: provider_paths.clone(),
                        account: provider_account.clone(),
                        credentials: credentials.clone(),
                        background_service: true,
                        external_shutdown: Some(provider_shutdown.clone()),
                        shared_owner_control: provider_owner_control.clone(),
                        owner_control_managed: true,
                        shared_manifest_write: Some(provider_manifest_write.clone()),
                        shared_probe_capacity: provider_probe_capacity.clone(),
                        shared_provider_readiness: Some(provider_readiness.clone()),
                        workspace_picker: provider_workspace_picker.clone(),
                    },
                )
                .await;
                let error = match result {
                    Ok(()) => break Ok(()),
                    Err(error) => error,
                };
                if cycle_started.elapsed() >= STABLE_AFTER {
                    failures = 0;
                }
                let mut retry_shutdown = Some(provider_shutdown.clone());
                let class = match classify_failure(error.as_ref()) {
                    // A bare 401/403 may deny one bot request; reconnecting the
                    // bot is the probe that decides.
                    FailureClass::AuthSuspect => match AuthToken::try_new(&credentials.bot_token) {
                        Ok(token) => settle_auth_suspect(
                            probe_session(&provider_config, &AuthCredential::AccessToken { token })
                                .await,
                        ),
                        Err(_) => FailureClass::Transient,
                    },
                    class => class,
                };
                match class {
                    FailureClass::NeedsSetup => {
                        // Retrying cannot help. Park this agent; siblings keep
                        // running. A missing runtime re-probes on its own; a
                        // revoked bot waits for setup, which restarts the service.
                        let (reason, message) = provider_park_reason(&installation, error.as_ref());
                        let ledger = FailureLedger::provider(&installation);
                        ledger.record_needs_setup(reason, &message, unix_now());
                        provider_readiness.mark_needs_setup(&installation_id, &message);
                        crate::telemetry::report_bridge_setup_required(
                            &installation.provider_id,
                            reason,
                        );
                        eprintln!(
                            "{provider_name} needs setup and is parked: {}",
                            safe_diagnostic(&message)
                        );
                        let recovered = park_until_runtime_recovers(
                            &installation,
                            reason,
                            PARKED_REPROBE_INTERVAL,
                            &mut retry_shutdown,
                        )
                        .await;
                        if !recovered {
                            break Ok(());
                        }
                        ledger.clear();
                        failures = 0;
                        provider_readiness.mark_restarting(&installation_id);
                        eprintln!("{provider_name} runtime is available again; starting it.");
                    }
                    class => {
                        failures = failures.saturating_add(1);
                        provider_readiness.mark_restarting(&installation_id);
                        crate::telemetry::report_bridge_runtime_error(
                            &installation.provider_id,
                            "provider_cycle",
                            error.as_ref(),
                            Some(failures),
                        );
                        let delay = match class {
                            FailureClass::ServerWait(wait) => wait,
                            _ => SERVICE_BACKOFF.jittered(failures),
                        };
                        eprintln!(
                            "{provider_name} bridge cycle failed; reconnecting in {} without affecting other agents: {}",
                            describe_delay(delay),
                            safe_diagnostic(&error.to_string())
                        );
                        tokio::select! {
                            _ = tokio::time::sleep(delay) => {}
                            _ = wait_for_control_shutdown(&mut retry_shutdown) => break Ok(()),
                        }
                    }
                }
            };
            (installation_id, provider_name, result)
        }));
    }

    let run_result: Result<(), Box<dyn std::error::Error>> = loop {
        tokio::select! {
            completed = providers.next(), if !providers.is_empty() => {
                let Some((installation_id, provider_name, result)) = completed else {
                    continue;
                };
                if shutdown_requested(&control_shutdown) {
                    break Ok(());
                }
                match result {
                    Ok(()) => eprintln!("{provider_name} bridge stopped."),
                    Err(error) => eprintln!(
                        "Provider {installation_id} stopped; other agent bridges remain available: {}",
                        safe_diagnostic(&error.to_string())
                    ),
                }
                if !supervisor.provider_stopped(&installation_id) {
                    if shutdown_requested(&control_shutdown) {
                        break Ok(());
                    }
                    health.mark_provider_unavailable();
                    break Err(io::Error::new(
                        io::ErrorKind::ConnectionAborted,
                        "all configured agent providers stopped",
                    ).into());
                }
            }
            end = wait_for_owner_connection_end(&mut owner_connection_end) => {
                let end = match end {
                    // Park only on an explicit revocation; otherwise rebuild
                    // the connection, since the owner client stopped listening.
                    OwnerConnectionEnd::Suspect => {
                        owner_end_after_probe(probe_session(&runtime_config, &owner_auth).await)
                    }
                    end => end,
                };
                break Err(match end {
                    OwnerConnectionEnd::Revoked => {
                        match clear_bridge_owner_authority(&paths, &owner_auth) {
                            Ok(_) => BridgeSetupRequired::new(
                                "owner_credential_expired",
                                OWNER_SIGN_IN_EXPIRED,
                            ).into(),
                            Err(error) => error,
                        }
                    }
                    OwnerConnectionEnd::Suspect | OwnerConnectionEnd::Lost => {
                        owner_connection_lost_error()
                    }
                });
            }
            _ = &mut service_stable, if service_recovery_pending => {
                service_ledger.clear();
                service_recovery_pending = false;
            }
            _ = wait_for_control_shutdown(&mut control_shutdown) => break Ok(()),
            _ = &mut termination => break Ok(()),
        }
    };

    let _ = shutdown_tx.send(true);
    let provider_shutdown_timed_out = tokio::time::timeout(Duration::from_secs(15), async {
        while let Some((installation_id, _, result)) = providers.next().await {
            if let Err(error) = result {
                eprintln!(
                    "Provider {installation_id} shutdown failed: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
        }
    })
    .await
    .is_err();
    let mut forced_shutdown_error = None;
    if provider_shutdown_timed_out {
        eprintln!("Timed out while stopping agent providers.");
        drop(providers);
        for installation in &account.providers {
            let lock_file = installation.state_dir.join("provider.process.lock");
            match reap_stale_process_host(&lock_file).await {
                Ok(true) => eprintln!(
                    "Stopped the remaining {} provider process group.",
                    installation.display_name
                ),
                Ok(false) => {}
                Err(error) => {
                    eprintln!(
                        "Could not stop the remaining {} provider process group: {}",
                        installation.display_name,
                        safe_diagnostic(&error.to_string())
                    );
                    forced_shutdown_error.get_or_insert(error);
                }
            }
        }
    }
    health.mark_stopped();
    control_server.close().await;
    if let Some(workspace_registrar) = workspace_registrar {
        workspace_registrar.close().await;
    }
    if let Some(owner_control) = owner_control {
        owner_control.shutdown().await?;
    }
    run_result?;
    if let Some(error) = forced_shutdown_error {
        return Err(error.into());
    }
    Ok(())
}

fn replace_owner_dm_chat_id(
    account: &mut AccountBridgeConfig,
    installation_id: &str,
    bot_user_id: i64,
    dm_chat_id: i64,
) -> Result<bool, Box<dyn std::error::Error>> {
    if dm_chat_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an invalid owner direct message",
        )
        .into());
    }
    let installation = account
        .providers
        .iter_mut()
        .find(|installation| installation.installation_id == installation_id)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "provider installation vanished while repairing its owner direct message",
            )
        })?;
    if installation.bot_user_id != bot_user_id {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "provider bot identity changed while repairing its owner direct message",
        )
        .into());
    }
    if installation.dm_chat_id == Some(dm_chat_id) {
        return Ok(false);
    }
    installation.dm_chat_id = Some(dm_chat_id);
    installation.greeting_sent = false;
    Ok(true)
}

async fn reconcile_owner_dm_chat_ids(
    paths: &BridgePaths,
    account: &mut AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
    owner_control: &OwnerControl,
) -> Result<(), Box<dyn std::error::Error>> {
    let _account_mutation_lock = acquire_account_mutation_lock(paths)?;
    let mut latest: AccountBridgeConfig = read_required_json(&paths.config)?;
    let mut repaired_providers = Vec::new();
    let installations = latest.providers.clone();
    for installation in &installations {
        let dm_chat_id = match owner_control
            .resolve_owner_dm_chat_id(installation.bot_user_id)
            .await
        {
            Ok(dm_chat_id) => dm_chat_id,
            Err(error) => {
                crate::telemetry::report_bridge_owner_dm_event(
                    &installation.provider_id,
                    "owner_dm_startup",
                    "owner_dm_resolution_failed",
                );
                return Err(error);
            }
        };
        if replace_owner_dm_chat_id(
            &mut latest,
            &installation.installation_id,
            installation.bot_user_id,
            dm_chat_id,
        )? {
            repaired_providers.push(installation.provider_id.clone());
        }
    }
    if repaired_providers.is_empty() {
        *account = latest;
        return Ok(());
    }
    if let Err(error) =
        validate_account(&latest, secrets).and_then(|_| write_private_json(&paths.config, &latest))
    {
        for provider_id in &repaired_providers {
            crate::telemetry::report_bridge_owner_dm_event(
                provider_id,
                "owner_dm_startup",
                "owner_dm_persistence_failed",
            );
        }
        return Err(error);
    }
    *account = latest;
    for provider_id in repaired_providers {
        crate::telemetry::report_bridge_owner_dm_event(
            &provider_id,
            "owner_dm_startup",
            "owner_dm_repaired",
        );
        log::warn!(
            target: "inline::bridge::trace",
            "phase=owner_dm_repaired provider_id={provider_id:?} source=service_startup",
        );
    }
    Ok(())
}

async fn wait_for_owner_connection_end(
    receiver: &mut Option<tokio::sync::mpsc::UnboundedReceiver<OwnerConnectionEnd>>,
) -> OwnerConnectionEnd {
    let Some(receiver) = receiver else {
        return std::future::pending().await;
    };
    match receiver.recv().await {
        Some(end) => end,
        None => std::future::pending().await,
    }
}

/// Repeated-failure state of each configured agent, read from local files so
/// `inline doctor` works even while the service is stopped.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BridgeRecoverySummary {
    pub(crate) provider: String,
    pub(crate) ok: bool,
    pub(crate) detail: String,
}

pub(crate) fn recovery_summaries(config: &Config) -> Vec<BridgeRecoverySummary> {
    let Ok(Some(loaded)) = load_installed_account(config) else {
        return Vec::new();
    };
    loaded
        .account
        .providers
        .iter()
        .map(|installation| {
            let check = service::recovery_check(&loaded.paths, installation);
            BridgeRecoverySummary {
                provider: installation.provider_id.clone(),
                ok: check.ok,
                detail: check.detail,
            }
        })
        .collect()
}

pub async fn status(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(loaded) = load_installed_account(config)? else {
        let result = service::not_installed_status();
        print_status(&result, json, json_format)?;
        return Err(ReportedCliFailure.into());
    };
    let results = provider_statuses(&loaded).await;
    print_provider_statuses(&results, json, json_format)?;
    ensure_provider_statuses_healthy(&results)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceOutput {
    provider: String,
    workspace_id: String,
    display_name: String,
    parent_hint: Option<String>,
    default_for_new_chats: bool,
}

pub fn workspace_add(
    config: &Config,
    provider_id: Option<&str>,
    path: PathBuf,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let provider = select_workspace_provider(&loaded.account, provider_id)?;
    let record = register_workspace(
        &loaded.paths,
        &loaded.account,
        &loaded.account.host_installation_id,
        provider.bot_user_id,
        path,
    )?;
    let output = WorkspaceOutput {
        provider: provider.provider_id.clone(),
        workspace_id: record.workspace_id.to_string(),
        display_name: record.display_name,
        parent_hint: record.parent_hint,
        default_for_new_chats: true,
    };
    if json {
        output::print_json(&output, json_format)?;
    } else {
        println!(
            "Registered {} for {} ({}). It is now the default for new chats; existing chats keep their selected folder.",
            output.display_name, output.provider, output.workspace_id
        );
    }
    Ok(())
}

pub fn workspace_list(
    config: &Config,
    provider_id: Option<&str>,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let provider = select_workspace_provider(&loaded.account, provider_id)?;
    let installation_id = InstallationId::new(provider.installation_id.clone())?;
    let store = BridgeStore::open(loaded.paths.provider_paths(provider).bridge_db)?;
    let default_workspace_id = store
        .default_workspace(&installation_id)?
        .map(|workspace| workspace.workspace_id);
    let choices = projects::project_choices(
        &store,
        &installation_id,
        default_workspace_id.as_ref(),
        projects::codex_projects_path(&provider.provider_id).as_deref(),
    )?;
    let output = choices
        .into_iter()
        .map(|choice| WorkspaceOutput {
            provider: provider.provider_id.clone(),
            workspace_id: choice.workspace_id.to_string(),
            display_name: choice.display_name,
            parent_hint: choice.parent_hint,
            default_for_new_chats: choice.selected,
        })
        .collect::<Vec<_>>();
    if json {
        output::print_json(&output, json_format)?;
    } else if output.is_empty() {
        println!(
            "No project folders are registered for {}.",
            provider.provider_id
        );
    } else {
        for workspace in output {
            println!(
                "{}{} ({})",
                workspace.display_name,
                workspace
                    .parent_hint
                    .as_deref()
                    .map(|hint| format!(" · {hint}"))
                    .unwrap_or_default(),
                workspace.workspace_id
            );
        }
    }
    Ok(())
}

fn select_workspace_provider<'a>(
    account: &'a AccountBridgeConfig,
    requested_provider_id: Option<&str>,
) -> Result<&'a ProviderInstallationConfig, Box<dyn std::error::Error>> {
    match requested_provider_id {
        Some(provider_id) => account
            .providers
            .iter()
            .find(|provider| provider.provider_id == provider_id)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("{provider_id} is not configured for this bridge"),
                )
                .into()
            }),
        None if account.providers.len() == 1 => Ok(&account.providers[0]),
        None => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "multiple agents are configured; choose one with --provider <codex|opencode|claude|amp>",
        )
        .into()),
    }
}

pub async fn start(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    service::start_service(&loaded.paths, &loaded.account, &loaded.secrets).await?;
    service::wait_for_all_providers_ready(&loaded.paths, &loaded.account, &loaded.secrets).await?;
    let results = provider_statuses(&loaded).await;
    print_provider_statuses(&results, json, json_format)?;
    ensure_provider_statuses_healthy(&results)
}

pub async fn stop(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let installation = primary_installation(&loaded.account)?;
    service::stop_service(
        &loaded.paths,
        &loaded.account,
        &loaded.secrets,
        installation,
    )
    .await?;
    let results = provider_statuses(&loaded).await;
    print_provider_statuses(&results, json, json_format)
}

pub async fn restart(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    service::restart_service(&loaded.paths, &loaded.account, &loaded.secrets).await?;
    service::wait_for_all_providers_ready(&loaded.paths, &loaded.account, &loaded.secrets).await?;
    let results = provider_statuses(&loaded).await;
    print_provider_statuses(&results, json, json_format)?;
    ensure_provider_statuses_healthy(&results)
}

pub async fn refresh_after_update(
    config: &Config,
    updated_binary: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    for loaded in load_all_installed_accounts(config)? {
        if let Err(error) = validate_account(&loaded.account, &loaded.secrets) {
            eprintln!(
                "Skipped restarting an agent bridge that needs setup: {}",
                safe_diagnostic(&error.to_string())
            );
            continue;
        }
        service::refresh_stable_binary(&loaded.paths, updated_binary)?;
        // The update itself succeeded. A bridge that is not healthy yet keeps
        // retrying (or re-probing) on the new binary by itself.
        let restarted = async {
            service::restart_service(&loaded.paths, &loaded.account, &loaded.secrets).await?;
            service::wait_for_all_providers_ready(&loaded.paths, &loaded.account, &loaded.secrets)
                .await
        }
        .await;
        if let Err(error) = restarted {
            eprintln!(
                "The agent bridge restarted on the new version but is not healthy yet: {}. Check `inline bridge status`.",
                safe_diagnostic(&error.to_string())
            );
        }
    }
    Ok(())
}

#[derive(Debug, Eq, PartialEq)]
enum LoginHeal {
    Nothing,
    Restart,
    RefreshOwnerSignIn,
}

fn login_heal_plan(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
) -> LoginHeal {
    let owner_sign_in_needed = owner_credential(secrets).is_err()
        || FailureLedger::service(paths)
            .load()
            .is_some_and(|record| record.needs_setup && record.failure.starts_with("owner_"));
    if owner_sign_in_needed {
        LoginHeal::RefreshOwnerSignIn
    } else if account_has_failure_records(paths, account) {
        LoginHeal::Restart
    } else {
        LoginHeal::Nothing
    }
}

/// After a successful `inline login`: if the installed bridge for this account
/// lost its owner sign-in, give it the new one; if the bridge recorded any
/// failures, restart it so everything retries now. A healthy bridge is left
/// alone. Returns a one-line note for the user when something changed.
pub(crate) async fn heal_after_login(
    config: &Config,
    owner_auth: AuthCredential,
) -> Result<Option<&'static str>, Box<dyn std::error::Error>> {
    let Some(loaded) = load_installed_account(config)? else {
        return Ok(None);
    };
    let owner_sign_in_needed =
        match login_heal_plan(&loaded.paths, &loaded.account, &loaded.secrets) {
            LoginHeal::Nothing => return Ok(None),
            LoginHeal::Restart => false,
            LoginHeal::RefreshOwnerSignIn => true,
        };
    if owner_sign_in_needed {
        let mut owner = crate::owner_session::OwnerSession::connect(config, owner_auth).await?;
        let me = owner
            .call(proto::GetMeInput {})
            .await?
            .user
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "GetMe returned no user"))?;
        if me.id != loaded.account.owner_user_id {
            return Ok(None);
        }
        let credential = owner.credential()?;
        let _account_mutation_lock = acquire_account_mutation_lock(&loaded.paths)?;
        let mut secrets: AccountBridgeSecrets = read_required_json(&loaded.paths.secrets)?;
        secrets.version = ACCOUNT_SECRETS_VERSION;
        secrets.owner_auth = Some(credential);
        secrets.owner_token.clear();
        validate_account(&loaded.account, &secrets)?;
        write_private_json(&loaded.paths.secrets, &secrets)?;
    }
    if !service::kick_service(&loaded.paths, &loaded.account, &loaded.secrets).await? {
        return Ok(None);
    }
    Ok(Some(if owner_sign_in_needed {
        "Reconnected the agent bridge with this sign-in and restarted it."
    } else {
        "Restarted the agent bridge so it retries now."
    }))
}

pub async fn doctor(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let mut results = Vec::with_capacity(loaded.account.providers.len());
    for installation in &loaded.account.providers {
        results.push(
            service::doctor(
                &loaded.paths,
                &loaded.account,
                &loaded.secrets,
                installation,
            )
            .await,
        );
    }
    let healthy = results.iter().all(|result| result.status == "healthy");
    if json {
        output::print_json(&results, json_format)?;
    } else {
        for result in &results {
            println!(
                "{}: {}",
                result
                    .runtime
                    .display_name
                    .as_deref()
                    .unwrap_or(&result.runtime.provider),
                result.status
            );
            for (label, check) in [
                ("Config", &result.config),
                ("Credentials", &result.secrets),
                ("Installed CLI", &result.installed_binary),
                ("Provider", &result.provider),
                ("Service", &result.service_definition),
                ("Recovery", &result.recovery),
            ] {
                println!(
                    "  {label}: {} — {}",
                    if check.ok { "ok" } else { "needs attention" },
                    check.detail
                );
            }
            println!("  Runtime: {}", result.runtime.status);
            #[cfg(target_os = "linux")]
            if let Some(detail) = &result.runtime.detail
                && !detail.is_empty()
            {
                println!("  Runtime detail: {detail}");
            }
        }
    }
    if healthy {
        Ok(())
    } else {
        Err(ReportedCliFailure.into())
    }
}

pub async fn uninstall(
    config: &Config,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let installation = primary_installation(&loaded.account)?;
    let definition = service::uninstall_service(
        &loaded.paths,
        &loaded.account,
        &loaded.secrets,
        installation,
    )
    .await?;
    let result = serde_json::json!({
        "status": "uninstalled",
        "serviceDefinition": definition,
        "preservedState": loaded.paths.root.display().to_string(),
        "providers": loaded.account.providers.iter().map(|provider| provider.provider_id.as_str()).collect::<Vec<_>>(),
    });
    if json {
        output::print_json(&result, json_format)?;
    } else {
        println!("Background bridge service uninstalled.");
        println!("Bots, credentials, configuration, and local state were preserved.");
        println!("State: {}", loaded.paths.root.display());
    }
    Ok(())
}

async fn provider_statuses(loaded: &LoadedAccount) -> Vec<service::BridgeStatus> {
    let mut results = Vec::with_capacity(loaded.account.providers.len());
    for installation in &loaded.account.providers {
        results.push(
            service::status(
                &loaded.paths,
                &loaded.account,
                &loaded.secrets,
                installation,
            )
            .await,
        );
    }
    results
}

fn print_provider_statuses(
    results: &[service::BridgeStatus],
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    if json {
        output::print_json(results, json_format)?;
        return Ok(());
    }
    for (index, result) in results.iter().enumerate() {
        if index > 0 {
            println!();
        }
        print_status(result, false, json_format)?;
        println!("Provider: {}", result.provider);
    }
    Ok(())
}

fn ensure_provider_statuses_healthy(
    results: &[service::BridgeStatus],
) -> Result<(), Box<dyn std::error::Error>> {
    if results.iter().all(|result| result.healthy) {
        Ok(())
    } else {
        Err(ReportedCliFailure.into())
    }
}

pub fn logs(
    config: &Config,
    maximum_lines: usize,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installed_account(config)?;
    let (paths, account) = match loaded {
        Some(loaded) => (loaded.paths, Some(loaded.account)),
        None => (BridgePaths::legacy(config), None),
    };
    let result = service::logs(&paths, account.as_ref(), maximum_lines);
    if json {
        output::print_json(&result, json_format)?;
    } else {
        if !result.providers.is_empty() {
            println!("Providers: {}", result.providers.join(", "));
        }
        if result.lines.is_empty() {
            println!("No bridge logs yet.");
        } else {
            for line in result.lines {
                println!("{line}");
            }
        }
    }
    Ok(())
}

async fn persist_provider_update(
    paths: &BridgePaths,
    installation: &ProviderInstallationConfig,
    manifest_write: &tokio::sync::Mutex<()>,
) -> Result<(), Box<dyn std::error::Error>> {
    let _guard = manifest_write.lock().await;
    let _account_mutation_lock = acquire_account_mutation_lock(paths)?;
    let mut latest: AccountBridgeConfig = read_required_json(&paths.config)?;
    replace_provider(&mut latest, installation.clone())?;
    write_private_json(&paths.config, &latest)?;
    Ok(())
}

async fn wait_for_standalone_termination(enabled: bool) {
    if enabled {
        wait_for_termination().await;
    } else {
        std::future::pending::<()>().await;
    }
}

struct ProviderRuntimeContext {
    paths: BridgePaths,
    account: AccountBridgeConfig,
    credentials: ProviderCredentials,
    background_service: bool,
    external_shutdown: Option<tokio::sync::watch::Receiver<bool>>,
    shared_owner_control: Option<Arc<OwnerControl>>,
    owner_control_managed: bool,
    shared_manifest_write: Option<Arc<tokio::sync::Mutex<()>>>,
    shared_probe_capacity: Arc<tokio::sync::Semaphore>,
    shared_provider_readiness: Option<ProviderReadiness>,
    workspace_picker: Option<WorkspacePickerEndpoint>,
}

async fn settle_nonfatal_turn_error(
    bot: &InlineClient,
    store: &BridgeStore,
    installation_id: &InstallationId,
    provider_id: &ProviderId,
    event_id: &str,
    error: &(dyn std::error::Error + 'static),
) {
    let record = match store.get_inbound(event_id) {
        Ok(Some(record)) if record.state == InboundState::Started => record,
        Ok(_) => return,
        Err(store_error) => {
            crate::telemetry::report_bridge_runtime_error(
                provider_id.as_str(),
                "turn_recovery_store",
                &store_error,
                None,
            );
            eprintln!(
                "Failed turn could not be reconciled from the durable inbox: {}",
                safe_diagnostic(&store_error.to_string())
            );
            return;
        }
    };
    let failure = safe_diagnostic(&error.to_string());
    if let Err(recovery_error) = publish_inbound_final_send(
        bot,
        store,
        event_id,
        record.delivery_chat_id,
        record.stream_message_id.map(InlineId::new),
        "Failed.",
        &failure_message(BridgeNotice::AgentTurnFailed, Some(&error.to_string())),
        InboundState::Failed,
        Some(&failure),
    )
    .await
    {
        crate::telemetry::report_bridge_runtime_error(
            provider_id.as_str(),
            "turn_recovery_delivery",
            recovery_error.as_ref(),
            None,
        );
        eprintln!(
            "Failed turn recovery is pending; later work can continue: {}",
            safe_diagnostic(&recovery_error.to_string())
        );
        if let Err(pending_error) = recover_pending_final_sends_with_transport(
            &InlineStreamMessageTransport(bot),
            store,
            installation_id,
            message_retry_delay,
        )
        .await
        {
            crate::telemetry::report_bridge_runtime_error(
                provider_id.as_str(),
                "turn_recovery_pending_delivery",
                pending_error.as_ref(),
                None,
            );
            eprintln!(
                "Pending failed-turn notice could not be delivered yet; later work can continue: {}",
                safe_diagnostic(&pending_error.to_string())
            );
        }
    }
}

fn active_bound_sessions(
    store: &BridgeStore,
    bindings: &HashMap<i64, BindingKey>,
) -> Result<HashSet<(ProviderId, inline_agent_bridge::ProviderSessionId)>, StoreError> {
    let mut sessions = HashSet::new();
    for binding in bindings.values() {
        if let Some(session) = store.get_binding(binding)? {
            sessions.insert(session);
        }
    }
    Ok(sessions)
}

fn pending_binding_has_free_lane(
    store: &BridgeStore,
    binding: &BindingKey,
    lanes: &HashMap<i64, tokio::sync::mpsc::Sender<LosslessEventDelivery>>,
    active_sessions: &HashSet<(ProviderId, inline_agent_bridge::ProviderSessionId)>,
) -> Result<bool, StoreError> {
    if lanes.contains_key(&binding.chat_id) {
        return Ok(false);
    }
    Ok(!store
        .get_binding(binding)?
        .is_some_and(|session| active_sessions.contains(&session)))
}

fn promote_turn_lane(
    lanes: &mut HashMap<i64, tokio::sync::mpsc::Sender<LosslessEventDelivery>>,
    bindings: &mut HashMap<i64, BindingKey>,
    source_chat_id: i64,
    target: BindingKey,
    sender: tokio::sync::mpsc::Sender<LosslessEventDelivery>,
) -> bool {
    if !lanes
        .get(&source_chat_id)
        .is_some_and(|current| current.same_channel(&sender))
        || lanes.contains_key(&target.chat_id)
    {
        return false;
    }
    lanes.remove(&source_chat_id);
    lanes.insert(target.chat_id, sender);
    bindings.remove(&source_chat_id);
    bindings.insert(target.chat_id, target);
    true
}

fn release_turn_lane(
    lanes: &mut HashMap<i64, tokio::sync::mpsc::Sender<LosslessEventDelivery>>,
    bindings: &mut HashMap<i64, BindingKey>,
    chat_id: i64,
    sender: &tokio::sync::mpsc::Sender<LosslessEventDelivery>,
) {
    if lanes
        .get(&chat_id)
        .is_some_and(|current| current.same_channel(sender))
    {
        lanes.remove(&chat_id);
        bindings.remove(&chat_id);
    }
}

async fn run_provider_installation(
    config: &Config,
    mut installation: ProviderInstallationConfig,
    context: ProviderRuntimeContext,
) -> Result<(), Box<dyn std::error::Error>> {
    let ProviderRuntimeContext {
        paths,
        mut account,
        credentials,
        background_service,
        mut external_shutdown,
        shared_owner_control,
        owner_control_managed,
        shared_manifest_write,
        shared_probe_capacity,
        shared_provider_readiness,
        workspace_picker,
    } = context;
    let configured_workspace = PathBuf::from(&installation.workspace);
    let standalone_runtime = external_shutdown.is_none();
    let _instance_lock = if standalone_runtime {
        Some(acquire_instance_lock(&paths.instance_lock)?)
    } else {
        None
    };
    let manifest_write =
        shared_manifest_write.unwrap_or_else(|| Arc::new(tokio::sync::Mutex::new(())));
    let secrets: AccountBridgeSecrets = read_required_json(&paths.secrets)?;
    validate_account(&account, &secrets)?;
    let policy = operator_policy_for_provider(&account, &installation.provider_id)?;
    let saved_credentials = provider_credentials(&secrets, &installation)?;
    if saved_credentials.bot_user_id != credentials.bot_user_id
        || saved_credentials.bot_token != credentials.bot_token
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "provider credentials changed before the bridge started",
        )
        .into());
    }
    ensure_private_dir(&installation.state_dir)?;
    let provider_paths = paths.provider_paths(&installation);

    let bot_store = SqliteStore::open(&provider_paths.bot_client_db)?;
    let backend = SdkBackend::builder()
        .api_base_url(config.api_base_url.clone())
        .realtime_url(config.realtime_url.clone())
        .identity(ClientIdentity::new(
            "agent-bridge",
            env!("CARGO_PKG_VERSION"),
        ))
        .store(bot_store.clone())
        .build()?;
    let bot = InlineClient::builder().backend(backend).build().spawn();
    let mut inline_events = bot.take_lossless_events().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AlreadyExists,
            "bridge lossless event stream was already claimed",
        )
    })?;
    let mut connect_request = ConnectRequest::new(AuthCredential::AccessToken {
        token: AuthToken::try_new(&credentials.bot_token)?,
    })
    .with_account_namespace(format!("bridge-bot-{}", installation.bot_user_id));
    if !installation.initial_cursor_seeded {
        connect_request = connect_request.start_after_current();
    }
    bot.connect(connect_request).await?;
    let connection_lease = ProviderConnectionLease::new(
        shared_provider_readiness.as_ref(),
        &installation.installation_id,
    );
    if !installation.initial_cursor_seeded {
        installation.initial_cursor_seeded = true;
        replace_provider(&mut account, installation.clone())?;
        persist_provider_update(&paths, &installation, &manifest_write).await?;
    }
    let owns_owner_control = !owner_control_managed;
    let owner_control = if owner_control_managed {
        Some(shared_owner_control.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotConnected,
                "shared owner authorization must be connected before starting agents",
            )
        })?)
    } else {
        let owner_control_seed_required = !account.owner_control_cursor_seeded;
        let owner_auth = owner_credential(&secrets)?;
        match OwnerControl::connect(
            config,
            &paths,
            account.owner_user_id,
            &owner_auth,
            owner_control_seed_required,
        )
        .await
        {
            Ok(control) => {
                if owner_control_seed_required {
                    account.owner_control_cursor_seeded = true;
                    let _account_mutation_lock = acquire_account_mutation_lock(&paths)?;
                    let mut latest: AccountBridgeConfig = read_required_json(&paths.config)?;
                    latest.owner_control_cursor_seeded = true;
                    write_private_json(&paths.config, &latest)?;
                }
                Some(Arc::new(control))
            }
            Err(error) => {
                if owner_control_error_invalidates_authentication(error.as_ref()) {
                    let _ = clear_bridge_owner_authority(&paths, &owner_auth)?;
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "bridge owner authorization expired; run Inline agent setup again",
                    )
                    .into());
                }
                return Err(error);
            }
        }
    };

    let dm_chat_id = InlineId::new(installation.dm_chat_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge installation does not contain an owner DM",
        )
    })?);
    if let Some(owner_control) = owner_control.as_ref()
        && let Err(error) = owner_control.follow_mode(dm_chat_id.get()).await
    {
        eprintln!(
            "Owner dialog state is unavailable: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    let bridge_store = Arc::new(BridgeStore::open(&provider_paths.bridge_db)?);
    let installation_id = InstallationId::new(installation.installation_id.clone())?;
    let provider_id = ProviderId::new(installation.provider_id.clone())?;
    let registered_at = now_seconds();
    bridge_store.put_installation(&InstallationRecord {
        installation_id: installation_id.clone(),
        provider_id: provider_id.clone(),
        display_name: installation.display_name.clone(),
        created_at: registered_at,
        updated_at: registered_at,
    })?;
    let missing = bridge_store.refresh_workspace_availability(&installation_id, registered_at)?;
    if !missing.is_empty() {
        eprintln!(
            "Removed {} unavailable project folder(s) from bridge recents.",
            missing.len()
        );
    }
    let workspace = match bridge_store.bound_chat_workspace(&installation_id, dm_chat_id.get())? {
        Some(workspace) => workspace,
        None => match bridge_store.default_workspace(&installation_id)? {
            Some(workspace) => {
                bridge_store.bind_chat_workspace(
                    &installation_id,
                    dm_chat_id.get(),
                    &workspace.workspace_id,
                    registered_at,
                )?;
                workspace
            }
            None => {
                let workspace_id = workspace_id(&configured_workspace)?;
                match bridge_store.workspace(&installation_id, &workspace_id)? {
                    Some(workspace) => workspace,
                    None => {
                        let workspace = bridge_store.select_workspace(
                            &installation_id,
                            &workspace_id,
                            &configured_workspace,
                            registered_at,
                        )?;
                        bridge_store.bind_chat_workspace(
                            &installation_id,
                            dm_chat_id.get(),
                            &workspace_id,
                            registered_at,
                        )?;
                        workspace
                    }
                }
            }
        },
    };
    let current_workspace_id = workspace.workspace_id.clone();
    let workspace = workspace.path;

    if v2_enabled_for(&installation.provider_id) {
        return run_v2_provider(V2Launch {
            installation: &installation,
            legacy_store: bridge_store.clone(),
            owner_user_id: account.owner_user_id,
            dm_chat_id: dm_chat_id.get(),
            workspace,
            machine_label: if account.host_label.trim().is_empty() {
                local_host_label()
            } else {
                account.host_label.clone()
            },
            allowlist: policy.allowed_user_ids().collect(),
            owner_control: owner_control.clone(),
            bot,
            inline_events,
            readiness: shared_provider_readiness.as_ref(),
            external_shutdown,
            standalone_runtime,
        })
        .await;
    }

    let provider_launch =
        ProviderLaunch::from_installation(&installation).map_err(provider_setup_required)?;
    let provider_ledger = FailureLedger::provider(&installation);
    let provider_name = provider_launch.provider_name();
    let binding = BindingKey {
        installation_id,
        chat_id: dm_chat_id.get(),
        workspace_id: current_workspace_id,
    };
    let active = ActiveConversation::new(binding.clone(), workspace.clone());
    let reply_thread_default =
        reply_thread_default_for_provider(&account, &installation.provider_id)?;
    let mut settings_identity = SettingsIdentity {
        owner_user_id: account.owner_user_id,
        owner_dm_chat_id: dm_chat_id.get(),
        bot_user_id: installation.bot_user_id,
        host_installation_id: if account.host_installation_id.trim().is_empty() {
            format!("legacy-host-{}", account.owner_user_id)
        } else {
            account.host_installation_id.clone()
        },
        host_label: if account.host_label.trim().is_empty() {
            local_host_label()
        } else {
            account.host_label.clone()
        },
        workspace_picker,
        codex_projects_path: projects::codex_projects_path(&installation.provider_id),
        codex_project_rpc: None,
        bot_store: bot_store.clone(),
        reply_thread_default,
    };
    let (deferred_inbound_tx, mut deferred_inbound_rx) =
        tokio::sync::mpsc::channel::<InboundRecord>(MAX_PENDING_VOICE_TRANSCRIPTS);
    let attachment_cache_dir = installation.state_dir.join("attachments");
    ensure_private_dir(&attachment_cache_dir)?;
    let claude_history = if installation.provider_id == "claude" {
        match adapter::verify_pinned_adapter_executable("claude", &installation.executable)
            .map_err(|_| ClaudeHistoryError::SdkUnavailable)
            .and_then(|executable| ClaudeHistoryRuntime::from_adapter_executable(&executable))
        {
            Ok(history) => Some(history),
            Err(_) => {
                eprintln!(
                    "Claude session history is unavailable because the pinned local SDK could not be verified."
                );
                None
            }
        }
    } else {
        None
    };
    let inbound_route = InboundRoute {
        store: bridge_store.clone(),
        installation_id: binding.installation_id.clone(),
        provider_id: ProviderId::new(installation.provider_id.clone())?,
        policy: Arc::new(RwLock::new(policy.clone())),
        owner_user_id: account.owner_user_id,
        host_label: settings_identity.host_label.clone(),
        owner_dm_chat_id: dm_chat_id.get(),
        bot_user_id: installation.bot_user_id,
        sibling_bot_user_ids: Arc::new(
            account
                .providers
                .iter()
                .map(|provider| provider.bot_user_id)
                .filter(|bot_user_id| *bot_user_id != installation.bot_user_id)
                .collect(),
        ),
        bot_username: installation.bot_username.clone(),
        bot_store: bot_store.clone(),
        attachment_cache_dir,
        owner_control: owner_control.clone(),
        accept_messages_after: installation.accept_messages_after,
        deferred_inbound_tx,
        pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
        claude_history,
        control_lane: Arc::new(tokio::sync::Semaphore::new(1)),
        control_epoch: ControlTaskEpoch::new(),
        bot_agent_resolver: BotAgentResolver::new(
            config.realtime_url.clone(),
            credentials.bot_token.clone(),
        ),
    };
    let inline_tools = inline_tool_configuration(Arc::new(InlineToolHost::new(
        bot.clone(),
        inbound_route.clone(),
        config.realtime_url.clone(),
        credentials.bot_token.clone(),
    )));

    // Keep the Inline event stream live while a slow or temporarily broken
    // local agent starts. Messages are durably queued and acknowledged instead
    // of sitting silent until ACP/app-server initialization finishes.
    let mut termination = Box::pin(wait_for_standalone_termination(standalone_runtime));
    let Some(spawned) = launch_provider_responsively(
        ResponsiveProviderLaunch {
            provider_launch: &provider_launch,
            installation: &installation,
            provider_name,
            bot: &bot,
            route: &inbound_route,
            readiness: shared_provider_readiness.as_ref(),
            installation_id: &installation.installation_id,
            probe_capacity: &shared_probe_capacity,
        },
        &mut inline_events,
        &mut external_shutdown,
        &mut termination,
    )
    .await?
    else {
        return Ok(());
    };
    let process_status = spawned.process_status.clone();
    let session_configuration_fingerprint =
        configure_provider_inline_tools(&spawned.driver, inline_tools.clone())?;
    let mut driver = Arc::new(spawned.driver);
    settings_identity.codex_project_rpc = projects::codex_driver(&driver);
    let mut sessions = Arc::new(
        ProviderSessionManager::new(driver.clone(), bridge_store.clone(), provider_id.clone())
            .with_session_configuration_fingerprint(session_configuration_fingerprint.clone()),
    );

    refresh_provider_configuration_catalog(
        &provider_id,
        &sessions,
        &bridge_store,
        &binding,
        &settings_identity,
        &bot,
        &inbound_route,
    )
    .await;

    recover_provider_inbox(
        &bot,
        &bridge_store,
        &binding.installation_id,
        InterruptionKind::BridgeRestart,
    )
    .await?;

    if !installation.greeting_sent {
        let workspace_label = workspace
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("project");
        let greeting = format!(
            "Hi — I’m ready to run {provider_name} in {workspace_label}. Send me a task whenever you’re ready."
        );
        let mut greeting_request = SendTextRequest::new(
            PeerRef::Chat {
                chat_id: dm_chat_id,
            },
            greeting,
        );
        greeting_request.external_id = Some(ExternalId::try_new(
            "agent-bridge",
            format!("{}-greeting-v2", installation.installation_id),
        )?);
        greeting_request.notification_mode =
            BridgeNotificationClass::ImportantNotice.notification_mode();
        send_text_with_retry(&bot, greeting_request).await?;
        installation.greeting_sent = true;
        replace_provider(&mut account, installation.clone())?;
        persist_provider_update(&paths, &installation, &manifest_write).await?;
    }

    let health = service::RuntimeHealth::ready();
    if let Some(description) = process_status.exit_description() {
        health.mark_provider_unavailable();
        provider_ledger.record(
            "provider_exited_during_startup",
            Some(&description),
            FailureClass::Transient,
            unix_now(),
        );
        return Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            format!(
                "{provider_name} exited during startup: {}",
                safe_diagnostic(&description)
            ),
        )
        .into());
    }
    let control_server = if background_service && external_shutdown.is_none() {
        Some(
            service::ControlServer::bind(
                &paths.control_socket,
                secrets.control_token.clone(),
                health.clone(),
            )
            .await?,
        )
    } else {
        None
    };
    let mut shutdown_rx = external_shutdown.take().or_else(|| {
        control_server
            .as_ref()
            .map(service::ControlServer::shutdown_receiver)
    });
    let mut provider_exit = Box::pin(wait_for_provider_exit(process_status, health.clone()));
    let mut provider_started_at = tokio::time::Instant::now();
    // Earlier failures are forgiven once the provider stays ready for a while.
    let mut provider_recovery_pending = provider_ledger.load().is_some();
    let mut provider_stable =
        Box::pin(tokio::time::sleep_until(provider_started_at + STABLE_AFTER));
    // Hand edits to the operator allowlist apply without a restart.
    let mut policy_reload = tokio::time::interval(POLICY_RELOAD_INTERVAL);
    policy_reload.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    if let Some(readiness) = shared_provider_readiness.as_ref() {
        readiness.mark_ready(&installation.installation_id);
    }

    if background_service {
        println!(
            "{provider_name} bridge ready for @{} in {}.",
            installation.bot_username,
            workspace.display()
        );
    } else {
        println!(
            "{provider_name} bridge is running for @{} in {}. Press Ctrl-C to stop this development process.",
            installation.bot_username,
            workspace.display()
        );
    }

    let run_result: Result<(), Box<dyn std::error::Error>> = async {
        const TURN_EVENT_QUEUE_CAPACITY: usize = 32;
        const TURN_EVENT_DISPATCH_DEADLINE: Duration = Duration::from_secs(2);

        let mut conversations = HashMap::from([(dm_chat_id.get(), active.clone())]);
        let mut active_turns =
            HashMap::<i64, tokio::sync::mpsc::Sender<LosslessEventDelivery>>::new();
        let mut active_turn_bindings = HashMap::<i64, BindingKey>::new();
        let (lane_promotion_tx, mut lane_promotions) =
            tokio::sync::mpsc::channel::<TurnLanePromotion>(TURN_LANE_PROMOTION_QUEUE_CAPACITY);
        let mut turns = futures_util::stream::FuturesUnordered::new();
        let mut catalog_refresh: Option<tokio::task::JoinHandle<()>> = None;
        let mut scan_cursor = None;

        let loop_result: Result<(), Box<dyn std::error::Error>> = 'runtime: loop {
            let candidates = bridge_store.pending_inbound_bindings_after(
                &binding.installation_id,
                scan_cursor,
                SCHEDULING_SCAN_BATCH_SIZE,
            )?;
            let scan_has_more = candidates.len() == SCHEDULING_SCAN_BATCH_SIZE;
            scan_cursor = if scan_has_more {
                candidates.last().map(|(ingest_order, _)| *ingest_order)
            } else {
                None
            };
            let mut active_sessions = active_bound_sessions(&bridge_store, &active_turn_bindings)?;
            let mut provider_release_started = false;
            let mut provider_admission_blocked = false;
            for (_, pending_binding) in candidates {
                if !pending_binding_has_free_lane(
                    &bridge_store,
                    &pending_binding,
                    &active_turns,
                    &active_sessions,
                )? {
                    continue;
                }
                match bridge_store.session_picker_thread_gate(
                    &pending_binding.installation_id,
                    pending_binding.chat_id,
                    now_seconds(),
                )? {
                    SessionPickerThreadGate::Opening => continue,
                    SessionPickerThreadGate::Failed => {
                        if let Some(record) =
                            bridge_store.take_next_inbound(&pending_binding, now_seconds())?
                        {
                            publish_inbound_final_send(
                                &bot,
                                &bridge_store,
                                &record.event_id,
                                record.binding.chat_id,
                                record.stream_message_id.map(InlineId::new),
                                "Failed.",
                                "This Codex session did not finish opening. Send /sessions in the bot's private DM and open it again before sending more messages here.",
                                InboundState::Failed,
                                Some("session thread setup is incomplete"),
                            )
                            .await?;
                        }
                        continue;
                    }
                    SessionPickerThreadGate::Ready => {}
                }
                // Do not claim durable work while an epoch-wide `/close` owns
                // the provider. Admission must be nonblocking here because
                // the close future is polled by this same supervisor loop.
                let Some(provider_admission_lease) = sessions.try_begin_provider_work()? else {
                    provider_admission_blocked = true;
                    break;
                };
                let Some(record) =
                    bridge_store
                        .take_next_inbound_if_session_ready(&pending_binding, now_seconds())?
                else {
                    continue;
                };
                // Queued work was admitted under the policy of its time.
                // Recheck the sender so a revoked operator, or a bot queued
                // before bots needed an allowlist entry, cannot run on replay.
                if !inbound_route.admits_sender(record.sender_user_id) {
                    bridge_store.fail_inbound(&record.event_id, "sender is not authorized")?;
                    continue;
                }
                let provider_epoch_release = record.sender_user_id == inbound_route.owner_user_id
                    && is_provider_epoch_release_command(
                        &record.direction.text,
                        &inbound_route.bot_username,
                    )
                    && (matches!(parse_command(&record.direction.text, &inbound_route.bot_username),
                            Ok(Some(command)) if command.name == "close")
                        || is_linked_codex_stop(&inbound_route, &record)?);
                let workspace = bridge_store
                    .workspace(
                        &pending_binding.installation_id,
                        &pending_binding.workspace_id,
                    )?
                    .filter(|workspace| {
                        provider_epoch_release || (record.sender_user_id == inbound_route.owner_user_id
                            && is_workspace_recovery_command(
                                &record.direction.text,
                                &inbound_route.bot_username,
                            ))
                            || (workspace.missing_since.is_none() && workspace.path.is_dir())
                    });
                let Some(workspace) = workspace else {
                    publish_inbound_final_send(
                        &bot,
                        &bridge_store,
                        &record.event_id,
                        record.binding.chat_id,
                        record.stream_message_id.map(InlineId::new),
                        "Failed.",
                        BridgeNotice::MissingWorkspace.message(),
                        InboundState::Failed,
                        Some("selected workspace is unavailable"),
                    )
                    .await?;
                    continue;
                };
                let provider_work_lease = if provider_epoch_release {
                    drop(provider_admission_lease);
                    None
                } else {
                    Some(provider_admission_lease)
                };
                let conversation = conversations
                    .entry(pending_binding.chat_id)
                    .or_insert_with(|| {
                        ActiveConversation::new(pending_binding.clone(), workspace.path.clone())
                    })
                    .clone();
                conversation.replace(pending_binding.clone(), workspace.path.clone());

                let (event_tx, mut event_rx) =
                    tokio::sync::mpsc::channel(TURN_EVENT_QUEUE_CAPACITY);
                active_turns.insert(pending_binding.chat_id, event_tx.clone());
                let task_bot = bot.clone();
                let task_sessions = sessions.clone();
                let task_store = bridge_store.clone();
                let task_route = inbound_route.clone();
                let task_identity = settings_identity.clone();
                let task_chat_id = pending_binding.chat_id;
                let task_event_id = record.event_id.clone();
                active_turn_bindings.insert(task_chat_id, pending_binding.clone());
                if let Some(session) = bridge_store.get_binding(&pending_binding)? {
                    active_sessions.insert(session);
                }
                let task_lane_sender = event_tx.clone();
                let task_lane_promotions = lane_promotion_tx.clone();
                turns.push(Box::pin(async move {
                    let result = run_inbound_turn(
                        &task_bot,
                        &mut event_rx,
                        &task_sessions,
                        &task_store,
                        &pending_binding,
                        &workspace.path,
                        &task_route,
                        &conversation,
                        &task_identity,
                        record,
                        provider_work_lease,
                        event_tx,
                        task_lane_promotions,
                    )
                    .await;
                    let final_chat_id = conversation.snapshot().binding.chat_id;
                    (task_chat_id, final_chat_id, task_event_id, task_lane_sender, result)
                }));
                // Give an owner `/close` the first chance to acquire the
                // epoch-wide writer. Continuing this batch could reserve a
                // later lane and make an otherwise-idle release report busy.
                if provider_epoch_release {
                    provider_release_started = true;
                    break;
                }
            }

            if provider_release_started || provider_admission_blocked {
                scan_cursor = None;
            }

            tokio::select! {
                biased;
                promotion = lane_promotions.recv() => {
                    let Some(promotion) = promotion else {
                        break 'runtime Err(io::Error::new(
                            io::ErrorKind::BrokenPipe,
                            "turn lane promotion channel closed",
                        ).into());
                    };
                    let mut accepted = active_turns
                        .get(&promotion.source_chat_id)
                        .is_some_and(|sender| sender.same_channel(&promotion.sender))
                        && !active_turns.contains_key(&promotion.delivery_chat_id);
                    if accepted {
                        match repair_promoted_conversation_cache(
                            &inbound_route,
                            &mut conversations,
                            promotion.source_chat_id,
                            promotion.delivery_chat_id,
                        ) {
                            Ok(()) => {
                                accepted = promote_turn_lane(
                                    &mut active_turns,
                                    &mut active_turn_bindings,
                                    promotion.source_chat_id,
                                    promotion.binding,
                                    promotion.sender,
                                );
                            }
                            Err(error) => {
                                accepted = false;
                                crate::telemetry::report_bridge_runtime_error(
                                    provider_id.as_str(),
                                    "turn_lane_promotion",
                                    &error,
                                    None,
                                );
                                eprintln!(
                                    "Turn lane promotion failed; preserving the source lane: {}",
                                    safe_diagnostic(&error.to_string())
                                );
                            }
                        }
                    }
                    let _ = promotion.acknowledged.send(accepted);
                }
                completed = turns.next(), if !turns.is_empty() => {
                    if let Some((source_chat_id, final_chat_id, event_id, sender, result)) = completed {
                        release_turn_lane(&mut active_turns, &mut active_turn_bindings, source_chat_id, &sender);
                        release_turn_lane(&mut active_turns, &mut active_turn_bindings, final_chat_id, &sender);
                        if let Err(error) = result {
                            crate::telemetry::report_bridge_runtime_error(
                                provider_id.as_str(),
                                "turn_runtime",
                                error.as_ref(),
                                None,
                            );
                            eprintln!(
                                "Agent turn failed; later work can continue: {}",
                                safe_diagnostic(&error.to_string())
                            );
                            if crate::telemetry::bridge_error_requires_provider_restart(
                                error.as_ref(),
                            ) {
                                break 'runtime Err(error);
                            }
                            settle_nonfatal_turn_error(
                                &bot,
                                &bridge_store,
                                &binding.installation_id,
                                &provider_id,
                                &event_id,
                                error.as_ref(),
                            )
                            .await;
                        }
                    }
                }
                _ = tokio::task::yield_now(), if scan_has_more && !provider_release_started && !provider_admission_blocked => {}
                deferred = deferred_inbound_rx.recv() => {
                    let Some(record) = deferred else {
                        break 'runtime Err(io::Error::new(
                            io::ErrorKind::BrokenPipe,
                            "deferred media channel closed",
                        ).into());
                    };
                    let admitted = match accept_or_resume_queued_confirmation(&bridge_store, &record)
                    {
                        Ok(admitted) => admitted,
                        Err(error) => {
                            crate::telemetry::report_bridge_runtime_error(
                                provider_id.as_str(),
                                "deferred_media_admission",
                                &error,
                                None,
                            );
                            eprintln!(
                                "Deferred media admission failed; later work can continue: {}",
                                safe_diagnostic(&error.to_string())
                            );
                            false
                        }
                    };
                    if inbound_route.allows(record.sender_user_id) && admitted {
                        log::trace!(
                            target: "inline::bridge::media",
                            "phase=voice_wait_elapsed event_id={:?} attachment_count={}",
                            record.event_id,
                            record.direction.attachments.len()
                        );
                    }
                }
                delivery = inline_events.recv_delivery() => {
                    let Some(delivery) = delivery else {
                        break 'runtime Err(io::Error::new(
                            io::ErrorKind::ConnectionAborted,
                            "Inline bot event stream closed",
                        ).into());
                    };
                    connection_lease.observe(delivery.event(), &bot);
                    let chat_id = actionable_event_chat_id(delivery.event());
                    let dispatch_chat_id = match approval_dispatch_chat_id(
                        delivery.event(),
                        &bridge_store,
                    ) {
                        Ok(chat_id) => chat_id.or_else(|| {
                            active_turn_event_chat_id(
                                delivery.event(),
                                inbound_route.bot_user_id,
                            )
                        }),
                        Err(error) => {
                            recover_failed_delivery(
                                &bot,
                                &delivery,
                                &inbound_route,
                                "active_turn_event_routing",
                                error.as_ref(),
                            )
                            .await;
                            continue 'runtime;
                        }
                    };
                    if let Some(dispatch_chat_id) = dispatch_chat_id
                        && let Some(sender) = active_turns.get(&dispatch_chat_id).cloned()
                    {
                        match tokio::time::timeout(
                            TURN_EVENT_DISPATCH_DEADLINE,
                            sender.reserve(),
                        )
                        .await
                        {
                            Ok(Ok(permit)) => {
                                permit.send(delivery);
                                continue 'runtime;
                            }
                            Ok(Err(_)) => {
                                active_turns.remove(&dispatch_chat_id);
                            }
                            Err(_) => {
                                active_turns.remove(&dispatch_chat_id);
                                let error = io::Error::new(
                                    io::ErrorKind::ConnectionAborted,
                                    "active turn stopped accepting Inline events; restarting its provider epoch",
                                );
                                recover_failed_delivery(
                                    &bot,
                                    &delivery,
                                    &inbound_route,
                                    "active_turn_event_dispatch",
                                    &error,
                                )
                                .await;
                                return Err(error.into());
                            }
                        }
                    }

                    let Some(chat_id) = chat_id else {
                        if let Err(error) = delivery.ack().await {
                            recover_failed_delivery(
                                &bot,
                                &delivery,
                                &inbound_route,
                                "non_actionable_delivery_ack",
                                &error,
                            )
                            .await;
                        }
                        continue 'runtime;
                    };
                    let settings_conversation = if matches!(
                        delivery.event(),
                        ClientEvent::BotInteraction(_)
                    ) {
                        let resolution = conversation_for_settings_event(
                            &inbound_route,
                            delivery.event(),
                            conversations.get(&chat_id),
                        )
                        .await;
                        match resolution {
                            Ok(SettingsConversationResolution::Unauthorized) => {
                                let handled: Result<(), Box<dyn std::error::Error>> = async {
                                    handle_unavailable_settings_event(
                                        &bot,
                                        delivery.event(),
                                        inbound_route.owner_user_id,
                                    )
                                    .await?;
                                    delivery.ack().await?;
                                    Ok(())
                                }
                                .await;
                                if let Err(error) = handled {
                                    recover_failed_delivery(
                                        &bot,
                                        &delivery,
                                        &inbound_route,
                                        "unauthorized_settings_delivery",
                                        error.as_ref(),
                                    )
                                    .await;
                                }
                                continue 'runtime;
                            }
                            Ok(SettingsConversationResolution::Ready(conversation)) => {
                                conversations.insert(chat_id, conversation.clone());
                                conversation
                            }
                            Err(ConversationResolutionError::MissingWorkspace) => {
                                let handled: Result<(), Box<dyn std::error::Error>> = async {
                                    handle_unavailable_settings_event_with_message(
                                        &bot,
                                        delivery.event(),
                                        inbound_route.owner_user_id,
                                        BridgeNotice::MissingWorkspace.message(),
                                    )
                                    .await?;
                                    delivery.ack().await?;
                                    Ok(())
                                }
                                .await;
                                if let Err(error) = handled {
                                    recover_failed_delivery(
                                        &bot,
                                        &delivery,
                                        &inbound_route,
                                        "missing_workspace_settings_delivery",
                                        error.as_ref(),
                                    )
                                    .await;
                                }
                                continue 'runtime;
                            }
                            Err(error) => {
                                recover_failed_delivery(
                                    &bot,
                                    &delivery,
                                    &inbound_route,
                                    "settings_conversation_resolution",
                                    &error,
                                )
                                .await;
                                continue 'runtime;
                            }
                        }
                    } else {
                        conversations
                            .get(&chat_id)
                            .cloned()
                            .unwrap_or_else(|| active.clone())
                    };
                    if let Err(error) = accept_idle_delivery(
                        &bot,
                        &delivery,
                        &inbound_route,
                        &SettingsRuntime {
                            sessions: &sessions,
                            store: &bridge_store,
                            active: &settings_conversation,
                            identity: &settings_identity,
                            turn_active: false,
                        },
                    )
                    .await
                    {
                        let restart = crate::telemetry::bridge_error_requires_provider_restart(
                            error.as_ref(),
                        );
                        recover_failed_delivery(
                            &bot,
                            &delivery,
                            &inbound_route,
                            "provider_ready_delivery",
                            error.as_ref(),
                        )
                        .await;
                        if restart {
                            break 'runtime Err(error);
                        }
                    }
                }
                _ = wait_for_control_shutdown(&mut shutdown_rx) => {
                    break 'runtime Ok(());
                }
                _ = &mut termination => {
                    break 'runtime Ok(());
                }
                _ = &mut provider_stable, if provider_recovery_pending => {
                    provider_ledger.clear();
                    provider_recovery_pending = false;
                }
                _ = policy_reload.tick() => {
                    if let Ok(policy) =
                        operator_policy_for_provider(&account, &installation.provider_id)
                        && policy != inbound_route.policy_snapshot()
                    {
                        inbound_route.replace_policy(policy);
                        eprintln!("{provider_name} reloaded its operator allowlist from ~/.inline/config.toml.");
                    }
                }
                description = &mut provider_exit => {
                    if let Some(task) = catalog_refresh.take() {
                        task.abort();
                        let _ = task.await;
                    }
                    health.mark_provider_unavailable();
                    crate::telemetry::report_bridge_provider_exit(provider_id.as_str());
                    sessions.seal_provider_epoch();
                    inbound_route.control_epoch.advance();
                    let control_lane_quiesced = inbound_route
                        .control_lane
                        .clone()
                        .acquire_owned()
                        .await
                        .map_err(|_| io::Error::other("session control lane closed"))?;
                    if let Some(readiness) = shared_provider_readiness.as_ref() {
                        readiness.mark_restarting(&installation.installation_id);
                    }
                    eprintln!(
                        "{provider_name} exited; keeping Inline connected while it restarts: {}",
                        safe_diagnostic(&description)
                    );
                    active_turns.clear();
                    active_turn_bindings.clear();
                    if tokio::time::timeout(Duration::from_secs(10), async {
                        while let Some((source_chat_id, delivery_chat_id, _event_id, _sender, result)) = turns.next().await {
                            if let Err(error) = result {
                                eprintln!(
                                    "Turn cleanup failed for source chat {source_chat_id}, delivery chat {delivery_chat_id}: {}",
                                    safe_diagnostic(&error.to_string())
                                );
                            }
                        }
                    })
                    .await
                    .is_err()
                    {
                        eprintln!("Timed out while interrupting turns for provider restart.");
                        turns = futures_util::stream::FuturesUnordered::new();
                    }
                    recover_provider_inbox(
                        &bot,
                        &bridge_store,
                        &binding.installation_id,
                        InterruptionKind::ProviderRestart,
                    )
                    .await?;
                    drop(control_lane_quiesced);
                    if let Err(error) = shutdown_provider_driver(
                        driver.as_ref(),
                        &installation,
                    )
                    .await
                    {
                        eprintln!(
                            "{provider_name} shutdown after provider exit failed: {}",
                            safe_diagnostic(&error.to_string())
                        );
                    }
                    if provider_started_at.elapsed() >= STABLE_AFTER {
                        provider_ledger.clear();
                    }
                    // Persisted, so a crash loop keeps backing off (jittered, up
                    // to five minutes) even across service restarts.
                    let mut restart_record = provider_ledger.record(
                        "provider_exited",
                        Some(&description),
                        FailureClass::Transient,
                        unix_now(),
                    );
                    provider_recovery_pending = true;

                    'restart: loop {
                        let delay = restart_record.retry_delay(unix_now());
                        if let Some(readiness) = shared_provider_readiness.as_ref() {
                            readiness.mark_restarting_with_detail(
                                &installation.installation_id,
                                &format!(
                                    "{provider_name} stopped unexpectedly; retrying in {}",
                                    describe_delay(delay)
                                ),
                            );
                        }
                        let mut retry_delay = Box::pin(tokio::time::sleep(delay));
                        loop {
                            tokio::select! {
                                _ = &mut retry_delay => break,
                                delivery = inline_events.recv_delivery() => {
                                    let Some(delivery) = delivery else {
                                        break 'runtime Err(io::Error::new(
                                            io::ErrorKind::ConnectionAborted,
                                            "Inline bot event stream closed while the provider was restarting",
                                        ).into());
                                    };
                                    connection_lease.observe(delivery.event(), &bot);
                                    if let Err(error) = accept_provider_unavailable_delivery(
                                        &bot,
                                        &delivery,
                                        &inbound_route,
                                    )
                                    .await
                                    {
                                        recover_failed_delivery(
                                            &bot,
                                            &delivery,
                                            &inbound_route,
                                            "provider_restart_backoff_delivery",
                                            error.as_ref(),
                                        )
                                        .await;
                                    }
                                }
                                _ = wait_for_control_shutdown(&mut shutdown_rx) => {
                                    break 'runtime Ok(());
                                }
                                _ = &mut termination => {
                                    break 'runtime Ok(());
                                }
                            }
                        }

                        let mut spawning =
                            Box::pin(provider_launch.spawn(env!("CARGO_PKG_VERSION")));
                        let restarted = loop {
                            tokio::select! {
                                result = &mut spawning => break result,
                                delivery = inline_events.recv_delivery() => {
                                    let Some(delivery) = delivery else {
                                        break 'runtime Err(io::Error::new(
                                            io::ErrorKind::ConnectionAborted,
                                            "Inline bot event stream closed while the provider was restarting",
                                        ).into());
                                    };
                                    connection_lease.observe(delivery.event(), &bot);
                                    if let Err(error) = accept_provider_unavailable_delivery(
                                        &bot,
                                        &delivery,
                                        &inbound_route,
                                    )
                                    .await
                                    {
                                        recover_failed_delivery(
                                            &bot,
                                            &delivery,
                                            &inbound_route,
                                            "provider_restarting_delivery",
                                            error.as_ref(),
                                        )
                                        .await;
                                    }
                                }
                                _ = wait_for_control_shutdown(&mut shutdown_rx) => {
                                    break 'runtime Ok(());
                                }
                                _ = &mut termination => {
                                    break 'runtime Ok(());
                                }
                            }
                        };
                        match restarted {
                            Ok(spawned) => {
                                let restarted_status = spawned.process_status.clone();
                                if let Some(description) = restarted_status.exit_description() {
                                    eprintln!(
                                        "{provider_name} exited during restart: {}",
                                        safe_diagnostic(&description)
                                    );
                                    if let Err(error) = shutdown_provider_driver(
                                        &spawned.driver,
                                        &installation,
                                    )
                                    .await
                                    {
                                        eprintln!(
                                            "{provider_name} cleanup after failed restart failed: {}",
                                            safe_diagnostic(&error.to_string())
                                        );
                                    }
                                    if let Some(problem) =
                                        provider_configuration_problem(&installation, None)
                                    {
                                        break 'runtime Err(provider_setup_required(problem).into());
                                    }
                                    restart_record = provider_ledger.record(
                                        "provider_exited_during_restart",
                                        Some(&description),
                                        FailureClass::Transient,
                                        unix_now(),
                                    );
                                    continue 'restart;
                                }
                                let session_configuration_fingerprint =
                                    configure_provider_inline_tools(
                                    &spawned.driver,
                                    inline_tools.clone(),
                                )?;
                                driver = Arc::new(spawned.driver);
                                settings_identity.codex_project_rpc = projects::codex_driver(&driver);
                                sessions = Arc::new(
                                    ProviderSessionManager::new(
                                        driver.clone(),
                                        bridge_store.clone(),
                                        provider_id.clone(),
                                    )
                                    .with_session_configuration_fingerprint(
                                        session_configuration_fingerprint,
                                    ),
                                );
                                provider_exit = Box::pin(wait_for_provider_exit(
                                    restarted_status,
                                    health.clone(),
                                ));
                                provider_started_at = tokio::time::Instant::now();
                                provider_stable
                                    .as_mut()
                                    .reset(provider_started_at + STABLE_AFTER);
                                health.mark_provider_ready();
                                if let Some(readiness) = shared_provider_readiness.as_ref() {
                                    readiness.mark_ready(&installation.installation_id);
                                }
                                eprintln!("{provider_name} restarted; queued work can resume.");
                                let refresh_provider_id = provider_id.clone();
                                let refresh_sessions = sessions.clone();
                                let refresh_store = bridge_store.clone();
                                let refresh_binding = binding.clone();
                                let refresh_identity = settings_identity.clone();
                                let refresh_bot = bot.clone();
                                let refresh_route = inbound_route.clone();
                                catalog_refresh = Some(tokio::spawn(async move {
                                    refresh_provider_configuration_catalog(
                                        &refresh_provider_id,
                                        &refresh_sessions,
                                        &refresh_store,
                                        &refresh_binding,
                                        &refresh_identity,
                                        &refresh_bot,
                                        &refresh_route,
                                    )
                                    .await;
                                }));
                                break 'restart;
                            }
                            Err(error) => {
                                if let Some(problem) = provider_configuration_problem(
                                    &installation,
                                    Some(error.as_ref()),
                                ) {
                                    break 'runtime Err(provider_setup_required(problem).into());
                                }
                                if classify_failure(error.as_ref()) == FailureClass::NeedsSetup {
                                    break 'runtime Err(error);
                                }
                                restart_record = provider_ledger.record_error(
                                    "provider_restart_failed",
                                    error.as_ref(),
                                    unix_now(),
                                );
                                crate::telemetry::report_bridge_runtime_error(
                                    provider_id.as_str(),
                                    "provider_restart",
                                    error.as_ref(),
                                    Some(restart_record.consecutive_failures),
                                );
                                eprintln!(
                                    "{provider_name} restart attempt failed: {}",
                                    safe_diagnostic(&error.to_string())
                                );
                            }
                        }
                    }
                }
            }
        };

        if let Some(task) = catalog_refresh.take() {
            task.abort();
            let _ = task.await;
        }

        active_turns.clear();
        active_turn_bindings.clear();
        if tokio::time::timeout(Duration::from_secs(10), async {
            while let Some((source_chat_id, delivery_chat_id, _event_id, _sender, result)) = turns.next().await {
                if let Err(error) = result {
                    eprintln!(
                        "Turn cleanup failed for source chat {source_chat_id}, delivery chat {delivery_chat_id}: {}",
                        safe_diagnostic(&error.to_string())
                    );
                }
            }
        })
        .await
        .is_err()
        {
            eprintln!("Timed out while stopping active bridge turns.");
        }
        loop_result
    }
    .await;

    sessions.seal_provider_epoch();
    inbound_route.control_epoch.advance();
    let _control_lane_quiesced = inbound_route
        .control_lane
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| io::Error::other("session control lane closed during shutdown"))?;
    if let Some(readiness) = shared_provider_readiness.as_ref() {
        readiness.mark_unavailable(&installation.installation_id);
    }
    health.mark_stopped();
    if let Some(history) = inbound_route.claude_history.as_ref() {
        history.cancel_imports(&bridge_store).await;
    }
    let driver_shutdown = shutdown_provider_driver(driver.as_ref(), &installation).await;
    let bot_shutdown = bot.shutdown().await;
    let owner_control_shutdown = match owner_control.filter(|_| owns_owner_control) {
        Some(owner_control) => owner_control.shutdown().await,
        None => Ok(()),
    };
    if let Some(control_server) = control_server {
        control_server.close().await;
    }
    run_result?;
    driver_shutdown?;
    bot_shutdown?;
    owner_control_shutdown?;
    Ok(())
}

/// Providers with a v2 driver. Every other provider (ACP agents such as
/// OpenCode) keeps running on v1, whatever `INLINE_BRIDGE_V2` says.
const V2_PROVIDERS: &[&str] = &["codex", "claude"];

/// Bridge v2 per provider while it is staged: `INLINE_BRIDGE_V2=codex,claude`
/// (or `all`, meaning every provider v2 supports). v1 stays the default.
fn v2_enabled_for(provider_id: &str) -> bool {
    v2_enabled_in(env::var("INLINE_BRIDGE_V2").ok().as_deref(), provider_id)
}

fn v2_enabled_in(setting: Option<&str>, provider_id: &str) -> bool {
    V2_PROVIDERS.contains(&provider_id)
        && setting.is_some_and(|value| {
            value.split(',').map(str::trim).any(|entry| {
                entry.eq_ignore_ascii_case("all") || entry.eq_ignore_ascii_case(provider_id)
            })
        })
}

struct V2Launch<'a> {
    installation: &'a ProviderInstallationConfig,
    legacy_store: Arc<BridgeStore>,
    owner_user_id: i64,
    dm_chat_id: i64,
    workspace: PathBuf,
    machine_label: String,
    allowlist: Vec<i64>,
    owner_control: Option<Arc<OwnerControl>>,
    bot: InlineClient,
    inline_events: inline_client::LosslessEventReceiver,
    readiness: Option<&'a ProviderReadiness>,
    external_shutdown: Option<tokio::sync::watch::Receiver<bool>>,
    standalone_runtime: bool,
}

/// Serves one provider on the v2 session contract instead of the v1 driver.
async fn run_v2_provider(launch: V2Launch<'_>) -> Result<(), Box<dyn std::error::Error>> {
    use inline_agent_bridge::harness::{ExecutableSource, HarnessDriver};
    let V2Launch {
        installation,
        legacy_store,
        owner_user_id,
        dm_chat_id,
        workspace,
        machine_label,
        allowlist,
        owner_control,
        bot,
        mut inline_events,
        readiness,
        mut external_shutdown,
        standalone_runtime,
    } = launch;
    let agent_name = if installation.display_name.trim().is_empty() {
        installation.provider_id.clone()
    } else {
        installation.display_name.clone()
    };
    let attachments_dir = installation.state_dir.join("attachments");
    // Inline tools, bound to the agent and its works (spec §4.8).
    let tools = v2::tools::Tools::new(v2::tools::ToolsConfig {
        bot: bot.clone(),
        provider: inline_agent_bridge::ProviderId::new(installation.provider_id.as_str())?,
        bot_user_id: installation.bot_user_id,
        owner_user_id,
        agent_name: agent_name.clone(),
        folder: workspace.clone(),
        attachments_dir: attachments_dir.clone(),
    });
    let (harness, vocabulary, executable): (Arc<dyn HarnessDriver>, _, PathBuf) =
        match installation.provider_id.as_str() {
            "codex" => {
                let ProviderLaunch::Codex(launch) = ProviderLaunch::from_installation(installation)
                    .map_err(provider_setup_required)?
                else {
                    return Err(io::Error::other("codex launch was not a Codex launch").into());
                };
                let executable = launch.executable.clone();
                let harness = inline_agent_driver_codex::harness::CodexHarness::new(
                    inline_agent_driver_codex::harness::CodexHarnessConfig {
                        launch,
                        source: ExecutableSource::Path,
                        pinned_sha256: None,
                        bridge_version: env!("CARGO_PKG_VERSION").to_owned(),
                        cache_root: installation.state_dir.join("v2"),
                    },
                );
                harness.configure_host_tools(tools.configuration());
                (Arc::new(harness), v2::render::Vocabulary::Codex, executable)
            }
            "claude" => {
                let executable = resolve_executable(Path::new("claude"))?;
                let mut config = inline_agent_driver_claude::harness::ClaudeHarnessConfig::new(
                    executable.clone(),
                    env!("CARGO_PKG_VERSION"),
                );
                config.host_tools = Some(tools.configuration());
                let harness = inline_agent_driver_claude::harness::ClaudeHarness::new(config);
                (
                    Arc::new(harness),
                    v2::render::Vocabulary::Claude,
                    executable,
                )
            }
            other => {
                return Err(io::Error::other(format!(
                    "bridge v2 does not support the {other} provider yet"
                ))
                .into());
            }
        };
    let runtime = v2::runtime::Runtime::new(
        v2::runtime::V2Config {
            vocabulary,
            agent_name,
            installation_id: installation.installation_id.clone(),
            owner_user_id,
            bot_user_id: installation.bot_user_id,
            bot_username: installation.bot_username.clone(),
            dm_chat_id,
            folder: workspace,
            machine_label,
            executable_path: Some(executable.display().to_string()),
            accept_messages_after: installation.accept_messages_after,
            allowlist,
            ledger_path: installation.state_dir.join("v2-ledger.sqlite"),
            attachments_dir,
        },
        bot.clone(),
        Arc::new(v2::runtime::OwnerConnection(owner_control.ok_or_else(
            || {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "bridge v2 needs the owner connection to record its work",
                )
            },
        )?)),
        harness,
        Some(tools),
    )?
    .with_folders(v2::folders::FolderSource {
        store: legacy_store.clone(),
        installation_id: InstallationId::new(installation.installation_id.clone())?,
    })
    .with_legacy_store(legacy_store);
    if let Some(readiness) = readiness {
        readiness.mark_ready(&installation.installation_id);
    }
    eprintln!(
        "{} bridge v2 ready for @{}.",
        installation.provider_id, installation.bot_username
    );
    let shutdown = async move {
        tokio::select! {
            _ = wait_for_standalone_termination(standalone_runtime) => {}
            _ = wait_for_control_shutdown(&mut external_shutdown) => {}
        }
    };
    runtime.run(&mut inline_events, shutdown).await
}

fn publishes_initial_provider_catalog(provider_id: &str) -> bool {
    matches!(provider_id, "codex" | "claude")
}

async fn refresh_provider_configuration_catalog(
    provider_id: &ProviderId,
    sessions: &Arc<ProviderSessionManager<ProviderDriver>>,
    bridge_store: &BridgeStore,
    binding: &BindingKey,
    settings_identity: &SettingsIdentity,
    bot: &InlineClient,
    inbound_route: &InboundRoute,
) {
    let catalog_projects = projects::project_choices(
        bridge_store,
        &binding.installation_id,
        Some(&binding.workspace_id),
        settings_identity.codex_projects_path.as_deref(),
    )
    .map_err(|error| safe_diagnostic(&error.to_string()));
    // Claude's ACP catalog is session-scoped, so loading it also prewarms the
    // exact workspace session reused by the first turn. Give cold startup more
    // room than an interactive picker, while keeping a broken provider bounded.
    let provider_catalog = if provider_id.as_str() == PROVIDER_ID {
        sessions.settings_catalog(binding, now_seconds()).await
    } else if publishes_initial_provider_catalog(provider_id.as_str()) {
        match tokio::time::timeout(
            INITIAL_PROVIDER_CATALOG_DEADLINE,
            sessions.settings_catalog(binding, now_seconds()),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(SessionManagerError::Driver(DriverError::Transient(
                "provider settings catalog timed out".to_string(),
            ))),
        }
    } else {
        Ok(DriverSettingsCatalog::default())
    };
    let cached = if catalog_projects.is_err() || provider_catalog.is_err() {
        published_agent_configuration_catalog(bot)
            .await
            .ok()
            .flatten()
    } else {
        None
    };
    if let Err(error) = &catalog_projects {
        eprintln!("Agent project choices are unavailable; retaining cached projects: {error}");
    }
    if let Err(error) = &provider_catalog {
        eprintln!(
            "Agent model choices are unavailable; retaining cached models: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    let candidate = refreshed_agent_configuration_catalog(
        catalog_projects.ok(),
        provider_catalog.as_ref().ok(),
        cached,
        &settings_identity.host_label,
    );
    let catalog = if let Some(candidate) = candidate {
        match advertise_settings_with_catalog(bot, candidate.clone())
            .await
            .map_err(|error| safe_diagnostic(&error.to_string()))
        {
            Ok(()) => Some(candidate),
            Err(diagnostic) => {
                eprintln!(
                    "Agent configuration choices could not be cached in Inline; keeping its last cached catalog: {}",
                    diagnostic
                );
                published_agent_configuration_catalog(bot)
                    .await
                    .unwrap_or_else(|error| {
                        eprintln!(
                            "Inline's cached Agent configuration could not be read: {}",
                            safe_diagnostic(&error.to_string())
                        );
                        None
                    })
            }
        }
    } else {
        published_agent_configuration_catalog(bot)
            .await
            .unwrap_or_else(|error| {
                eprintln!(
                    "Inline's cached Agent configuration could not be read: {}",
                    safe_diagnostic(&error.to_string())
                );
                None
            })
    };
    if let Some(catalog) = catalog {
        inbound_route
            .bot_agent_resolver
            .store_configuration_catalog(catalog);
    }
}

async fn shutdown_provider_driver(
    driver: &ProviderDriver,
    installation: &ProviderInstallationConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    match tokio::time::timeout(Duration::from_secs(5), driver.shutdown()).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(shutdown_error)) => {
            let lock_file = installation.state_dir.join("provider.process.lock");
            if let Err(cleanup_error) = reap_stale_process_host(&lock_file).await {
                return Err(io::Error::other(format!(
                    "provider shutdown failed: {shutdown_error}; process cleanup also failed: {cleanup_error}"
                ))
                .into());
            }
            Err(shutdown_error.into())
        }
        Err(_) => {
            eprintln!(
                "{} did not acknowledge shutdown within five seconds; stopping its process group.",
                installation.display_name
            );
            let lock_file = installation.state_dir.join("provider.process.lock");
            reap_stale_process_host(&lock_file).await?;
            Ok(())
        }
    }
}

mod setup;
use setup::*;
mod runtime;
use runtime::*;
mod helpers;
use helpers::*;
mod backoff;
use backoff::*;
mod session_probe;
use session_probe::*;

#[cfg(test)]
#[path = "bridge/tests.rs"]
mod tests;
