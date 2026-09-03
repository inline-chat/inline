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
    ApprovalDecision, ApprovalOption, ApprovalRecord, BindingKey, BridgeStore, ChatSettingsRecord,
    CommandChoiceAction, CommandChoiceClaimContext, CommandChoiceClaimOutcome,
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
    TriggerResolver, TurnCoordinator, TurnInput, TurnOptions, TurnOutcome, TurnTiming,
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
use crate::errors::{CliError, ReportedCliFailure};
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
use allowlist_ui::*;
use approval_ui::*;
use copy::{BridgeNotice, session_open_notice};
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
const MAX_ACCOUNT_CONCURRENT_TURNS: usize = 4;

mod account;
use account::*;
mod commands;
use commands::*;
mod claude_history;
use claude_history::*;
mod session_browser;
use session_browser::*;
mod settings;
use settings::*;
mod owner_control;
mod projects;
use owner_control::{
    OwnerControl, owner_control_error_invalidates_authentication, owner_control_error_is_retryable,
};
mod workspace_rpc;
use workspace_rpc::*;
mod routing;
use routing::*;
mod context;
use context::*;

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

pub async fn run_service(
    config_path: PathBuf,
    trace: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let config_path = fs::canonicalize(config_path)?;
    let paths = BridgePaths::for_config_path(&config_path)?;
    let (mut account, secrets) = load_account_files(&paths)?;
    validate_account(&account, &secrets)?;
    let runtime_config = Config {
        api_base_url: account.api_base_url.clone(),
        realtime_url: account.realtime_url.clone(),
        secrets_path: paths.root.join("owner-secrets-unused.json"),
        state_path: paths.root.join("owner-state-unused.json"),
        data_dir: paths.root.clone(),
        release_manifest_url: None,
        release_install_url: None,
    };
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
    let _instance_lock = acquire_instance_lock(&paths.instance_lock)?;
    let owner_control_seed_required = !account.owner_control_cursor_seeded;
    let owner_auth = owner_credential(&secrets)?;
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
            Err(error) if owner_control_error_invalidates_authentication(error.as_ref()) => {
                let _ = clear_bridge_owner_authority(&paths, &owner_auth)?;
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "bridge owner authorization expired; run Inline agent setup again",
                )
                .into());
            }
            Err(error) if owner_control_error_is_retryable(error.as_ref()) => {
                owner_connection_failures = owner_connection_failures.saturating_add(1);
                crate::telemetry::report_bridge_runtime_error(
                    "owner",
                    "owner_startup",
                    error.as_ref(),
                    Some(owner_connection_failures),
                );
                let delay = provider_restart_delay(owner_connection_failures);
                eprintln!(
                    "Owner connection unavailable; bridge will retry in {} seconds: {}",
                    delay.as_secs(),
                    safe_diagnostic(&error.to_string())
                );
                tokio::time::sleep(delay).await;
            }
            Err(error) => return Err(error),
        }
    };
    let mut owner_authentication_invalidation = owner_control
        .as_ref()
        .map(|control| control.authentication_invalidation_receiver());
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
    let turn_capacity = Arc::new(tokio::sync::Semaphore::new(MAX_ACCOUNT_CONCURRENT_TURNS));
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
        let provider_turn_capacity = turn_capacity.clone();
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
                        shared_turn_capacity: provider_turn_capacity.clone(),
                        shared_probe_capacity: provider_probe_capacity.clone(),
                        shared_provider_readiness: Some(provider_readiness.clone()),
                        workspace_picker: provider_workspace_picker.clone(),
                    },
                )
                .await;
                match result {
                    Ok(()) => break Ok(()),
                    Err(error) => {
                        failures = failures.saturating_add(1);
                        provider_readiness.mark_restarting(&installation_id);
                        crate::telemetry::report_bridge_runtime_error(
                            &installation.provider_id,
                            "provider_cycle",
                            error.as_ref(),
                            Some(failures),
                        );
                        eprintln!(
                            "{provider_name} bridge cycle failed; reconnecting without affecting other agents: {}",
                            safe_diagnostic(&error.to_string())
                        );
                        let mut delay = Box::pin(tokio::time::sleep(provider_restart_delay(failures)));
                        let mut retry_shutdown = Some(provider_shutdown.clone());
                        tokio::select! {
                            _ = &mut delay => {}
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
            _ = wait_for_owner_authentication_invalidation(&mut owner_authentication_invalidation) => {
                let terminal_error = match clear_bridge_owner_authority(&paths, &owner_auth) {
                    Ok(_) => io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "bridge owner authorization expired; run Inline agent setup again",
                    ).into(),
                    Err(error) => error,
                };
                break Err(terminal_error);
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

async fn wait_for_owner_authentication_invalidation(
    receiver: &mut Option<tokio::sync::watch::Receiver<bool>>,
) {
    let Some(receiver) = receiver else {
        std::future::pending::<()>().await;
        return;
    };
    loop {
        if *receiver.borrow() {
            return;
        }
        if receiver.changed().await.is_err() {
            std::future::pending::<()>().await;
            return;
        }
    }
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
        validate_account(&loaded.account, &loaded.secrets)?;
        service::refresh_stable_binary(&loaded.paths, updated_binary)?;
        service::restart_service(&loaded.paths, &loaded.account, &loaded.secrets).await?;
        service::wait_for_all_providers_ready(&loaded.paths, &loaded.account, &loaded.secrets)
            .await?;
    }
    Ok(())
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
    shared_turn_capacity: Arc<tokio::sync::Semaphore>,
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
        "I couldn’t finish that turn, but the bridge is still available. Please try again.",
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
        shared_turn_capacity,
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

    let provider_launch = ProviderLaunch::from_installation(&installation)
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
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

    let catalog_projects = projects::project_choices(
        &bridge_store,
        &binding.installation_id,
        Some(&binding.workspace_id),
        settings_identity.codex_projects_path.as_deref(),
    );
    // Claude's ACP catalog is session-scoped, so loading it also prewarms the
    // exact workspace session reused by the first turn. Bound that startup
    // read so a slow provider cannot hold the Inline event stream indefinitely.
    let provider_catalog = if provider_id.as_str() == PROVIDER_ID {
        sessions.settings_catalog(&binding, now_seconds()).await
    } else if publishes_initial_provider_catalog(provider_id.as_str()) {
        match tokio::time::timeout(
            SETTINGS_DEADLINE,
            sessions.settings_catalog(&binding, now_seconds()),
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
    let candidate = match (catalog_projects, provider_catalog) {
        (Ok(projects), Ok(provider_catalog)) => Some(agent_configuration_catalog(
            projects,
            &provider_catalog,
            &settings_identity.host_label,
        )),
        (projects, provider_catalog) => {
            if let Err(error) = projects {
                eprintln!(
                    "Agent project choices are unavailable; keeping Inline's last cached catalog: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
            if let Err(error) = provider_catalog {
                eprintln!(
                    "Agent model choices are unavailable; keeping Inline's last cached catalog: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
            None
        }
    };
    let catalog = if let Some(candidate) = candidate {
        match advertise_settings_with_catalog(&bot, candidate.clone()).await {
            Ok(()) => Some(candidate),
            Err(error) => {
                eprintln!(
                    "Agent configuration choices could not be cached in Inline; keeping its last cached catalog: {}",
                    safe_diagnostic(&error.to_string())
                );
                published_agent_configuration_catalog(&bot)
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
        published_agent_configuration_catalog(&bot)
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
            format!("{}-greeting-v1", installation.installation_id),
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
    let mut provider_restart_failures = 0_u32;
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
        let (lane_promotion_tx, mut lane_promotions) =
            tokio::sync::mpsc::channel::<TurnLanePromotion>(MAX_ACCOUNT_CONCURRENT_TURNS);
        let mut turns = futures_util::stream::FuturesUnordered::new();

        let loop_result: Result<(), Box<dyn std::error::Error>> = 'runtime: loop {
            while active_turns.len() < MAX_ACCOUNT_CONCURRENT_TURNS {
                let mut pending_binding = None;
                let mut incomplete_session_binding = None;
                for candidate in
                    bridge_store.pending_inbound_bindings(&binding.installation_id, 64)?
                {
                    if active_turns.contains_key(&candidate.chat_id) {
                        continue;
                    }
                    match bridge_store.session_picker_thread_gate(
                            &candidate.installation_id,
                            candidate.chat_id,
                            now_seconds(),
                        )? {
                        SessionPickerThreadGate::Ready => {
                            pending_binding = Some(candidate);
                            break;
                        }
                        SessionPickerThreadGate::Opening => continue,
                        SessionPickerThreadGate::Failed => {
                            incomplete_session_binding = Some(candidate);
                            break;
                        }
                    }
                }
                if let Some(binding) = incomplete_session_binding {
                    if let Some(record) =
                        bridge_store.take_next_inbound(&binding, now_seconds())?
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
                let Some(pending_binding) = pending_binding else {
                    break;
                };
                let Ok(turn_capacity_permit) =
                    shared_turn_capacity.clone().try_acquire_owned()
                else {
                    break;
                };
                // Do not claim durable work while an epoch-wide `/close` owns
                // the provider. Admission must be nonblocking here because
                // the close future is polled by this same supervisor loop.
                let Some(provider_admission_lease) = sessions.try_begin_provider_work()? else {
                    break;
                };
                let Some(record) =
                    bridge_store
                        .take_next_inbound_if_session_ready(&pending_binding, now_seconds())?
                else {
                    continue;
                };
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
                let task_lane_promotions = lane_promotion_tx.clone();
                turns.push(Box::pin(async move {
                    let _turn_capacity_permit = turn_capacity_permit;
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
                    (task_chat_id, final_chat_id, task_event_id, result)
                }));
                // Give an owner `/close` the first chance to acquire the
                // epoch-wide writer. Continuing this batch could reserve a
                // later lane and make an otherwise-idle release report busy.
                if provider_epoch_release {
                    break;
                }
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
                                active_turns.remove(&promotion.source_chat_id);
                                active_turns.insert(promotion.delivery_chat_id, promotion.sender);
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
                    if let Some((source_chat_id, final_chat_id, event_id, result)) = completed {
                        active_turns.remove(&source_chat_id);
                        active_turns.remove(&final_chat_id);
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
                        shared_turn_capacity.available_permits() == 0,
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
                description = &mut provider_exit => {
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
                    if tokio::time::timeout(Duration::from_secs(10), async {
                        while let Some((source_chat_id, delivery_chat_id, _event_id, result)) = turns.next().await {
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
                    if provider_started_at.elapsed() >= Duration::from_secs(60) {
                        provider_restart_failures = 0;
                    } else {
                        provider_restart_failures = provider_restart_failures.saturating_add(1);
                    }

                    'restart: loop {
                        let delay = provider_restart_delay(provider_restart_failures);
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
                                    provider_restart_failures =
                                        provider_restart_failures.saturating_add(1);
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
                                health.mark_provider_ready();
                                if let Some(readiness) = shared_provider_readiness.as_ref() {
                                    readiness.mark_ready(&installation.installation_id);
                                }
                                eprintln!("{provider_name} restarted; queued work can resume.");
                                break 'restart;
                            }
                            Err(error) => {
                                provider_restart_failures =
                                    provider_restart_failures.saturating_add(1);
                                crate::telemetry::report_bridge_runtime_error(
                                    provider_id.as_str(),
                                    "provider_restart",
                                    error.as_ref(),
                                    Some(provider_restart_failures),
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

        active_turns.clear();
        if tokio::time::timeout(Duration::from_secs(10), async {
            while let Some((source_chat_id, delivery_chat_id, _event_id, result)) = turns.next().await {
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

fn publishes_initial_provider_catalog(provider_id: &str) -> bool {
    matches!(provider_id, "codex" | "claude")
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

#[cfg(test)]
#[path = "bridge/tests.rs"]
mod tests;
