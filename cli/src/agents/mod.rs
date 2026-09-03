mod bot;
mod catalog;
mod discovery;
mod hermes;
mod openclaw;
mod process;

use std::cell::{Cell, RefCell};
use std::io::{self, IsTerminal, Write};
use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};
use dialoguer::{Confirm, Select};

use crate::bridge;
use crate::config::Config;
use crate::errors::{CliError, JsonCliError, ReportedCliFailure};
use crate::output::JsonFormat;

pub(crate) use catalog::AgentTarget;
use catalog::TargetFamily;
pub(crate) use discovery::search_directories as harness_search_directories;
use discovery::{InstalledTarget, installed_target, installed_targets};

pub(crate) const AGENTS_PROTOCOL_VERSION: u32 = 1;
pub(crate) const AGENTS_DOCUMENTATION_URL: &str = "https://inline.chat/docs/agents";

pub(super) struct GatewaySetupOutcome {
    pub(super) integration_action: &'static str,
    pub(super) integration_version: String,
    pub(super) service_action: &'static str,
    pub(super) ready: bool,
}

pub(super) struct GatewayPreflight {
    pub(super) configured_bot_id: Option<i64>,
}

pub(super) struct SetupProgressReporter {
    protocol_version: Option<u32>,
    human_output: bool,
    phase: Cell<&'static str>,
    changes: RefCell<Vec<String>>,
    started_at: std::time::Instant,
    retry: String,
}

impl SetupProgressReporter {
    fn new(protocol_version: Option<u32>, human_output: bool) -> Self {
        Self {
            protocol_version,
            human_output,
            phase: Cell::new("preflight"),
            changes: RefCell::new(Vec::new()),
            started_at: std::time::Instant::now(),
            retry: String::new(),
        }
    }

    pub(super) fn started(&self, phase: &'static str) {
        self.phase.set(phase);
        self.emit("phase.started", phase, None);
    }

    pub(super) fn completed(&self, phase: &'static str, outcome: &'static str) {
        if phase != "preflight" && phase != "verification" {
            self.changes.borrow_mut().push(format!("{phase}_{outcome}"));
        }
        self.emit("phase.completed", phase, Some(outcome));
    }

    fn emit(&self, event: &'static str, phase: &'static str, outcome: Option<&'static str>) {
        log::debug!(
            "setup {event} phase={phase} outcome={} elapsed_ms={}",
            outcome.unwrap_or("pending"),
            self.started_at.elapsed().as_millis()
        );
        if let Some(protocol_version) = self.protocol_version {
            if let Ok(line) = app_progress_event_line(protocol_version, event, phase, outcome) {
                println!("{line}");
                let _ = io::stdout().flush();
            }
        } else if self.human_output {
            eprintln!("{}", setup_progress_message(event, phase, outcome));
        }
    }
}

fn setup_progress_message(
    event: &'static str,
    phase: &'static str,
    outcome: Option<&'static str>,
) -> &'static str {
    match (event, phase, outcome) {
        ("phase.started", "preflight", _) => "Checking local setup requirements...",
        ("phase.started", "integration", _) => "Configuring the agent integration...",
        ("phase.started", "bot", _) => "Creating or reusing the Inline bot...",
        ("phase.started", "access", _) => "Applying bot access controls...",
        ("phase.started", "service", _) => {
            "Starting the local bridge service; this can take up to 90 seconds..."
        }
        ("phase.started", "verification", _) => "Verifying that the agent is ready...",
        ("phase.completed", "preflight", _) => "Local setup requirements are ready.",
        ("phase.completed", "integration", _) => "Agent integration configured.",
        ("phase.completed", "bot", Some("reused")) => "Existing Inline bot reused.",
        ("phase.completed", "bot", _) => "Inline bot configured.",
        ("phase.completed", "access", _) => "Bot access controls configured.",
        ("phase.completed", "service", Some("skipped")) => "Bridge service restart skipped.",
        ("phase.completed", "service", _) => "Local bridge service started.",
        ("phase.completed", "verification", Some("skipped")) => {
            "Agent readiness verification skipped."
        }
        ("phase.completed", "verification", _) => "Agent is ready.",
        _ => "Agent setup is progressing...",
    }
}

fn app_progress_event_line(
    protocol_version: u32,
    event: &'static str,
    phase: &'static str,
    outcome: Option<&'static str>,
) -> Result<String, serde_json::Error> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ProgressEvent {
        protocol_version: u32,
        event: &'static str,
        phase: &'static str,
        message: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        timeout_seconds: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        outcome: Option<&'static str>,
    }
    serde_json::to_string(&ProgressEvent {
        protocol_version,
        event,
        phase,
        message: setup_progress_message(event, phase, outcome),
        timeout_seconds: (event == "phase.started" && phase == "service").then_some(90),
        outcome,
    })
}

#[derive(Subcommand)]
pub(crate) enum AgentsCommand {
    #[command(about = "Discover supported local agent harnesses without making changes")]
    Discover,
    #[command(about = "Set up an installed local agent as an Inline bot")]
    Setup(AgentsSetupArgs),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub(crate) enum AccessMode {
    Owner,
    Allowlist,
    Open,
    Disabled,
}

#[derive(Args, Clone)]
pub(crate) struct AgentsSetupArgs {
    /// Agent harness to configure. Prompts from installed harnesses when omitted.
    #[arg(long, value_enum)]
    pub(crate) target: Option<AgentTarget>,
    /// Named harness profile to configure instead of its default profile.
    #[arg(long, value_name = "NAME")]
    pub(crate) profile: Option<String>,
    /// Workspace folder for coding-agent harnesses.
    #[arg(long, value_name = "PATH")]
    pub(crate) folder: Option<PathBuf>,
    /// Reuse an existing Inline bot by user ID.
    #[arg(long, value_name = "ID")]
    pub(crate) bot_id: Option<i64>,
    /// Display name for a bot created during setup.
    #[arg(long, value_name = "NAME")]
    pub(crate) bot_name: Option<String>,
    /// Username for a bot created during setup.
    #[arg(long, value_name = "USERNAME")]
    pub(crate) bot_username: Option<String>,
    /// Who may invoke the configured agent through Inline.
    #[arg(long, value_enum, default_value = "owner")]
    pub(crate) access: AccessMode,
    /// Additional Inline user ID to allow; may be repeated.
    #[arg(long = "allow-user", value_name = "ID")]
    pub(crate) allow_users: Vec<i64>,
    /// Refuse to install or upgrade required external integrations.
    #[arg(long)]
    pub(crate) no_install: bool,
    /// Configure the harness without restarting its managed service.
    #[arg(long)]
    pub(crate) no_restart: bool,
    /// Replace a conflicting bot credential or foreign integration.
    #[arg(long)]
    pub(crate) replace: bool,
    /// Validate and preview setup without changing the harness or Inline.
    #[arg(long)]
    pub(crate) dry_run: bool,
    /// Disable prompts; all required selections must be provided as flags.
    #[arg(long)]
    pub(crate) non_interactive: bool,
    /// Emit versioned NDJSON setup events for a native app host.
    #[arg(long, value_name = "VERSION", hide = true)]
    pub(crate) app_protocol: Option<u32>,
}

pub(crate) struct ResolvedSetup {
    pub(crate) args: AgentsSetupArgs,
    pub(crate) installed: InstalledTarget,
    pub(crate) non_interactive: bool,
}

fn setup_retry_command(args: &AgentsSetupArgs) -> String {
    let mut command = "inline agents setup".to_string();
    if let Some(target) = args.target {
        command.push_str(&format!(" --target {}", target.descriptor().id));
    }
    command.push_str(" --non-interactive --verbose");
    // Setup options affect identity, workspace, and permissions. A retry must
    // never silently switch to the default profile/bot or broaden its scope.
    let mut value = |flag: &str, value: String| {
        let quoted = if cfg!(windows) {
            format!("'{}'", value.replace('\'', "''"))
        } else {
            format!("'{}'", value.replace('\'', "'\\''"))
        };
        command.push_str(&format!(" {flag} {quoted}"));
    };
    if let Some(profile) = &args.profile {
        value("--profile", profile.clone());
    }
    if let Some(folder) = &args.folder {
        value("--folder", folder.display().to_string());
    }
    if let Some(id) = args.bot_id {
        value("--bot-id", id.to_string());
    }
    if let Some(name) = &args.bot_name {
        value("--bot-name", name.clone());
    }
    if let Some(username) = &args.bot_username {
        value("--bot-username", username.clone());
    }
    value("--access", access_name(args.access).to_string());
    for id in &args.allow_users {
        value("--allow-user", id.to_string());
    }
    for (enabled, flag) in [
        (args.no_install, "--no-install"),
        (args.no_restart, "--no-restart"),
        (args.replace, "--replace"),
        (args.dry_run, "--dry-run"),
    ] {
        if enabled {
            command.push(' ');
            command.push_str(flag);
        }
    }
    command
}

pub(crate) fn discover(
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let output = discovery_output(&installed_targets());
    if json {
        crate::output::print_json(&output, json_format)?;
    } else {
        let installed = output
            .targets
            .iter()
            .filter(|target| target.installed)
            .collect::<Vec<_>>();
        if installed.is_empty() {
            println!("No supported local agent harnesses were found.");
            println!("Setup guide: {AGENTS_DOCUMENTATION_URL}");
        } else {
            println!("Installed agent harnesses:");
            for target in installed {
                println!("  {} ({})", target.display_name, target.id);
            }
        }
    }
    Ok(())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentDiscoveryOutput {
    protocol_version: u32,
    action: &'static str,
    documentation_url: &'static str,
    targets: Vec<AgentDiscoveryTarget>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentDiscoveryTarget {
    id: &'static str,
    display_name: &'static str,
    family: TargetFamily,
    installed: bool,
}

fn discovery_output(installed: &[InstalledTarget]) -> AgentDiscoveryOutput {
    AgentDiscoveryOutput {
        protocol_version: AGENTS_PROTOCOL_VERSION,
        action: "agents.discover",
        documentation_url: AGENTS_DOCUMENTATION_URL,
        targets: catalog::TARGETS
            .iter()
            .map(|descriptor| AgentDiscoveryTarget {
                id: descriptor.id,
                display_name: descriptor.display_name,
                family: descriptor.family,
                installed: installed
                    .iter()
                    .any(|candidate| candidate.descriptor.target == descriptor.target),
            })
            .collect(),
    }
}

pub(crate) fn resolve_setup(
    mut args: AgentsSetupArgs,
    json: bool,
) -> Result<ResolvedSetup, Box<dyn std::error::Error>> {
    debug_assert!(catalog::bridge_catalog_matches());
    validate_common_args(&args)?;
    if args.app_protocol.is_some() && !json {
        return Err(CliError::invalid_args("--app-protocol requires --json").into());
    }
    let non_interactive =
        args.non_interactive || json || !io::stdin().is_terminal() || !io::stderr().is_terminal();
    let installed = if let Some(target) = args.target {
        installed_target(target).ok_or_else(|| {
            cli_error(
                "target_not_installed",
                format!(
                    "{} is not installed locally. Install it first, then rerun setup.",
                    target.descriptor().display_name
                ),
            )
        })?
    } else {
        let installed = installed_targets();
        match installed.as_slice() {
            [] => {
                return Err(cli_error(
                    "no_local_agents",
                    "No supported local agent installations were found (Hermes, OpenClaw, Codex, OpenCode, Claude, or Amp).",
                )
                .into());
            }
            [only] => only.clone(),
            many if non_interactive => {
                let ids = many
                    .iter()
                    .map(|candidate| candidate.descriptor.id)
                    .collect::<Vec<_>>()
                    .join(", ");
                return Err(cli_error(
                    "target_selection_required",
                    format!("Multiple installed agents were found ({ids}); pass --target <id>."),
                )
                .into());
            }
            many => {
                let labels = many
                    .iter()
                    .map(|candidate| candidate.descriptor.display_name)
                    .collect::<Vec<_>>();
                let selection = Select::new()
                    .with_prompt("Choose an installed agent")
                    .items(&labels)
                    .default(0)
                    .interact()?;
                many[selection].clone()
            }
        }
    };
    args.target = Some(installed.descriptor.target);
    if !non_interactive && !args.dry_run {
        args.access = prompt_access(installed.descriptor.family, args.access)?;
    }
    validate_target_args(&args, installed.descriptor.family)?;
    if !non_interactive && !args.dry_run {
        println!();
        println!("Target: {}", installed.descriptor.display_name);
        println!("Access: {}", access_name(args.access));
        println!(
            "Integration installation: {}",
            if args.no_install {
                "disabled"
            } else {
                "allowed"
            }
        );
        println!(
            "Service restart: {}",
            if args.no_restart {
                "disabled"
            } else {
                "allowed"
            }
        );
        if !Confirm::new()
            .with_prompt("Set up this agent in Inline?")
            .default(true)
            .interact()?
        {
            return Err(cli_error("setup_cancelled", "Agent setup was cancelled.").into());
        }
    }
    Ok(ResolvedSetup {
        args,
        installed,
        non_interactive,
    })
}

fn prompt_access(
    family: TargetFamily,
    current: AccessMode,
) -> Result<AccessMode, Box<dyn std::error::Error>> {
    let modes: &[AccessMode] = match family {
        TargetFamily::Gateway => &[
            AccessMode::Owner,
            AccessMode::Allowlist,
            AccessMode::Open,
            AccessMode::Disabled,
        ],
        TargetFamily::Bridge => &[AccessMode::Owner, AccessMode::Allowlist],
    };
    let labels = modes
        .iter()
        .map(|mode| match mode {
            AccessMode::Owner => "Owner only (recommended)",
            AccessMode::Allowlist => "Owner and allowlisted users",
            AccessMode::Open => "Anyone who can reach the bot",
            AccessMode::Disabled => "Disabled",
        })
        .collect::<Vec<_>>();
    let default = modes.iter().position(|mode| *mode == current).unwrap_or(0);
    let selection = Select::new()
        .with_prompt("Choose who can use the bot")
        .items(&labels)
        .default(default)
        .interact()?;
    Ok(modes[selection])
}

fn access_name(access: AccessMode) -> &'static str {
    match access {
        AccessMode::Owner => "owner",
        AccessMode::Allowlist => "allowlist",
        AccessMode::Open => "open",
        AccessMode::Disabled => "disabled",
    }
}

pub(crate) async fn setup(
    config: &Config,
    owner_auth: Option<inline_client::AuthCredential>,
    resolved: ResolvedSetup,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let target = resolved.installed.descriptor.target;
    let app_protocol = resolved.args.app_protocol;
    let mut progress = SetupProgressReporter::new(app_protocol, !json);
    progress.retry = setup_retry_command(&resolved.args);
    if resolved.args.dry_run {
        let preflight = match target {
            AgentTarget::Openclaw => openclaw::preflight(&resolved.installed, &resolved.args)
                .await
                .map(|_| ()),
            AgentTarget::Hermes => hermes::preflight(&resolved.installed, &resolved.args)
                .await
                .map(|_| ()),
            AgentTarget::Codex | AgentTarget::Opencode | AgentTarget::Claude | AgentTarget::Amp => {
                Ok(())
            }
        };
        if let Err(error) = preflight {
            return report_setup_failure(error, target, &progress, false, json, json_format);
        }
        return print_dry_run(&resolved, json, json_format, app_protocol);
    }
    let owner_auth = owner_auth.ok_or_else(CliError::not_authenticated)?;
    match target {
        AgentTarget::Codex | AgentTarget::Opencode | AgentTarget::Claude | AgentTarget::Amp => {
            let outcome = match bridge::setup_provider_core_with_progress(
                config,
                owner_auth,
                target.descriptor().id,
                resolved.args.folder,
                resolved.args.bot_name,
                bridge::ProviderSetupOptions {
                    quiet_adapter_install: true,
                    allow_adapter_install: !resolved.args.no_install,
                    manage_service: !resolved.args.no_restart,
                    operator_user_ids: Some(resolved.args.allow_users),
                },
                |event| match event {
                    bridge::ProviderSetupProgress::Started(phase) => progress.started(phase),
                    bridge::ProviderSetupProgress::Completed(phase, outcome) => {
                        progress.completed(phase, outcome)
                    }
                },
            )
            .await
            {
                Ok(outcome) => outcome,
                Err(error) => {
                    return report_setup_failure(
                        error,
                        target,
                        &progress,
                        progress.phase.get() != "preflight",
                        json,
                        json_format,
                    );
                }
            };
            print_bridge_result(outcome, json, json_format, app_protocol)
        }
        AgentTarget::Openclaw | AgentTarget::Hermes => {
            progress.started("preflight");
            let preflight = match target {
                AgentTarget::Openclaw => {
                    openclaw::preflight(&resolved.installed, &resolved.args).await
                }
                AgentTarget::Hermes => hermes::preflight(&resolved.installed, &resolved.args).await,
                _ => unreachable!(),
            };
            let preflight = match preflight {
                Ok(preflight) => {
                    progress.completed("preflight", "ready");
                    preflight
                }
                Err(error) => {
                    return report_setup_failure(
                        error,
                        target,
                        &progress,
                        false,
                        json,
                        json_format,
                    );
                }
            };
            let instance = gateway_instance(resolved.args.profile.as_deref());
            progress.started("bot");
            let bot = match bot::ensure_gateway_bot(
                config,
                owner_auth,
                resolved.installed.descriptor,
                &instance,
                &resolved.args,
                preflight.configured_bot_id,
            )
            .await
            {
                Ok(bot) => {
                    progress.completed("bot", bot.action);
                    bot
                }
                Err(error) => {
                    return report_setup_failure(error, target, &progress, true, json, json_format);
                }
            };
            let outcome = match target {
                AgentTarget::Openclaw => {
                    openclaw::setup(&resolved.installed, &bot, &resolved.args, &progress).await
                }
                AgentTarget::Hermes => {
                    hermes::setup(&resolved.installed, &bot, &resolved.args, &progress).await
                }
                _ => unreachable!(),
            };
            let outcome = match outcome {
                Ok(outcome) => outcome,
                Err(error) => {
                    return report_setup_failure(error, target, &progress, true, json, json_format);
                }
            };
            print_gateway_result(
                resolved.installed.descriptor,
                &instance,
                &bot,
                outcome,
                json,
                json_format,
                app_protocol,
            )
        }
    }
}

pub(crate) fn report_setup_preflight_failure(
    error: Box<dyn std::error::Error>,
    args: &AgentsSetupArgs,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut progress = SetupProgressReporter::new(args.app_protocol, !json);
    progress.retry = setup_retry_command(args);
    report_setup_failure_for_target(error, args.target, &progress, false, json, json_format)
}

fn report_setup_failure(
    error: Box<dyn std::error::Error>,
    target: AgentTarget,
    progress: &SetupProgressReporter,
    may_have_mutated: bool,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    report_setup_failure_for_target(
        error,
        Some(target),
        progress,
        may_have_mutated,
        json,
        json_format,
    )
}

fn report_setup_failure_for_target(
    error: Box<dyn std::error::Error>,
    target: Option<AgentTarget>,
    progress: &SetupProgressReporter,
    may_have_mutated: bool,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct FailureOutput<'a> {
        protocol_version: u32,
        ok: bool,
        action: &'static str,
        status: &'static str,
        documentation_url: &'static str,
        target: Option<&'a str>,
        failed_phase: &'static str,
        timed_out: bool,
        changes: &'a [String],
        recovery_commands: &'a [&'static str],
        #[serde(skip_serializing_if = "Option::is_none")]
        diagnostic_report_path: Option<String>,
        retry: String,
        error: JsonCliError,
    }

    let phase = progress.phase.get();
    let target_id = target.map(|target| target.descriptor().id);
    let changes = progress.changes.borrow();
    let mut payload = crate::diagnostics::error_payload(error.as_ref());
    let timed_out = payload.code == "timeout";
    const SERVICE_RECOVERY_COMMANDS: &[&str] = &[
        "inline bridge status --json --pretty",
        "inline bridge doctor --json --pretty",
        "inline bridge logs --lines 200 --json --pretty",
    ];
    const CODEX_INTEGRATION_RECOVERY_COMMANDS: &[&str] = &["codex --version", "codex login status"];
    let recovery_commands = if timed_out && phase == "service" {
        payload.hint = Some(
            "The local bridge did not become ready before the deadline. Its completed setup changes were kept; inspect bridge status, doctor, and logs before retrying."
                .to_string(),
        );
        SERVICE_RECOVERY_COMMANDS
    } else if payload.code == "provider_integration_failed"
        && phase == "integration"
        && target_id == Some("codex")
    {
        CODEX_INTEGRATION_RECOVERY_COMMANDS
    } else {
        &[]
    };
    crate::diagnostics::log_error(error.as_ref());
    log::debug!(
        "setup failed target={} phase={phase} completed_changes={:?}",
        target_id.unwrap_or("unselected"),
        &*changes
    );
    let report_summary = format!(
        "agents.setup failed target={} phase={phase} code={} completed_changes={:?}: {}",
        target_id.unwrap_or("unselected"),
        payload.code,
        &*changes,
        payload.message
    );
    let diagnostic_report_path = match crate::diagnostics::write_failure_report(&report_summary) {
        Ok(path) => path.map(|path| path.display().to_string()),
        Err(report_error) => {
            log::debug!(
                "could not save verbose diagnostic report: {}",
                crate::diagnostics::safe_text(&report_error.to_string())
            );
            None
        }
    };
    crate::telemetry::report(&payload, target_id, Some(phase));
    let retry = progress.retry.clone();
    let status = if may_have_mutated || !changes.is_empty() {
        "partial"
    } else {
        "failed"
    };
    if json {
        let json_format = if progress.protocol_version.is_some() {
            JsonFormat::Compact
        } else {
            json_format
        };
        let output = FailureOutput {
            protocol_version: AGENTS_PROTOCOL_VERSION,
            ok: false,
            action: "agents.setup",
            status,
            documentation_url: AGENTS_DOCUMENTATION_URL,
            target: target_id,
            failed_phase: phase,
            timed_out,
            changes: &changes,
            recovery_commands,
            diagnostic_report_path,
            retry,
            error: payload,
        };
        eprintln!("{}", crate::output::json_string(&output, json_format)?);
    } else {
        if timed_out {
            eprintln!("Agent setup timed out during {phase}: {}", payload.message);
        } else {
            eprintln!("Agent setup failed during {phase}: {}", payload.message);
        }
        eprintln!("Code: {}", payload.code);
        if let Some(status) = payload.status {
            eprintln!("Status: {status}");
        }
        if let Some(hint) = &payload.hint {
            eprintln!("Hint: {hint}");
        }
        for example in &payload.examples {
            eprintln!("  {example}");
        }
        if !changes.is_empty() {
            eprintln!("Completed changes: {}", changes.join(", "));
        }
        if !recovery_commands.is_empty() {
            eprintln!("Next steps:");
            for command in recovery_commands {
                eprintln!("  {command}");
            }
        }
        if let Some(path) = &diagnostic_report_path {
            eprintln!("Diagnostic report: {path}");
            eprintln!("Review this report, then attach it when contacting Inline support.");
        } else {
            eprintln!(
                "Diagnostics: repeat the command with --verbose (twice for trace detail) to save a shareable failure report."
            );
        }
        eprintln!("Retry: {retry}");
        eprintln!("Setup guide: {AGENTS_DOCUMENTATION_URL}");
    }
    Err(ReportedCliFailure.into())
}

fn print_bridge_result(
    outcome: bridge::ProviderSetupOutcome,
    json: bool,
    json_format: JsonFormat,
    app_protocol: Option<u32>,
) -> Result<(), Box<dyn std::error::Error>> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ResultOutput<'a> {
        protocol_version: u32,
        ok: bool,
        action: &'static str,
        status: &'static str,
        documentation_url: &'static str,
        open_url: String,
        target: &'a str,
        family: &'static str,
        instance: &'a str,
        bot: BotOutput<'a>,
        integration: IntegrationOutput<'a>,
        service: ServiceOutput<'a>,
        mapping: MappingOutput,
    }
    #[derive(serde::Serialize)]
    struct BotOutput<'a> {
        id: i64,
        username: &'a str,
        name: &'a str,
    }
    #[derive(serde::Serialize)]
    struct IntegrationOutput<'a> {
        kind: &'static str,
        action: &'static str,
        version: &'a str,
    }
    #[derive(serde::Serialize)]
    struct ServiceOutput<'a> {
        kind: &'static str,
        action: &'static str,
        ready: bool,
        status: &'a str,
    }
    #[derive(serde::Serialize)]
    struct MappingOutput {
        source: &'static str,
        action: &'static str,
    }
    let ready = outcome.background_service != "restart_required";
    let output = ResultOutput {
        protocol_version: AGENTS_PROTOCOL_VERSION,
        ok: true,
        action: "agents.setup",
        status: if ready { "ready" } else { "configured" },
        documentation_url: AGENTS_DOCUMENTATION_URL,
        open_url: format!("in://user/{}", outcome.bot_user_id),
        target: outcome.provider,
        family: "bridge",
        instance: &outcome.installation_id,
        bot: BotOutput {
            id: outcome.bot_user_id,
            username: &outcome.bot_username,
            name: &outcome.display_name,
        },
        integration: IntegrationOutput {
            kind: "bridge_provider",
            action: "configured",
            version: &outcome.provider_version,
        },
        service: ServiceOutput {
            kind: "inline_bridge",
            action: if ready { "started" } else { "skipped" },
            ready,
            status: &outcome.background_service,
        },
        mapping: MappingOutput {
            source: "bridge_account",
            action: "upserted",
        },
    };
    if json {
        print_setup_result(&output, json_format, app_protocol)?;
    } else {
        if ready {
            println!("{} is ready in Inline.", outcome.display_name);
        } else {
            println!("{} is configured in Inline.", outcome.display_name);
        }
        println!(
            "Provider: {} ({})",
            outcome.provider, outcome.provider_version
        );
        println!("Bot: @{} ({})", outcome.bot_username, outcome.bot_user_id);
        println!("Open: in://user/{}", outcome.bot_user_id);
        println!("Background service: {}", outcome.background_service);
        if !ready {
            println!("Restart required before the bot is ready.");
        }
    }
    Ok(())
}

fn validate_common_args(args: &AgentsSetupArgs) -> Result<(), Box<dyn std::error::Error>> {
    if args
        .app_protocol
        .is_some_and(|version| version != AGENTS_PROTOCOL_VERSION)
    {
        return Err(CliError::invalid_args(format!(
            "unsupported --app-protocol version; expected {AGENTS_PROTOCOL_VERSION}"
        ))
        .into());
    }
    if args.allow_users.iter().any(|id| *id <= 0) {
        return Err(CliError::invalid_args("--allow-user IDs must be positive").into());
    }
    if args.access != AccessMode::Allowlist && !args.allow_users.is_empty() {
        return Err(
            CliError::invalid_args("--allow-user is valid only with --access allowlist").into(),
        );
    }
    if args.bot_id.is_some_and(|id| id <= 0) {
        return Err(CliError::invalid_args("--bot-id must be positive").into());
    }
    if let Some(username) = args.bot_username.as_deref() {
        bot::normalize_username(username)?;
    }
    if let Some(profile) = args.profile.as_deref()
        && !valid_profile(profile)
    {
        return Err(CliError::invalid_args(
            "--profile must start with a letter or number and contain at most 64 letters, numbers, underscores, or hyphens",
        )
        .into());
    }
    Ok(())
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && profile
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn gateway_instance(profile: Option<&str>) -> String {
    match profile {
        Some(profile) if profile != "default" => format!("profile:{profile}"),
        _ => "default".to_string(),
    }
}

fn print_gateway_result(
    descriptor: &'static catalog::TargetDescriptor,
    instance: &str,
    bot: &bot::ManagedBot,
    outcome: GatewaySetupOutcome,
    json: bool,
    json_format: JsonFormat,
    app_protocol: Option<u32>,
) -> Result<(), Box<dyn std::error::Error>> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ResultOutput<'a> {
        protocol_version: u32,
        ok: bool,
        action: &'static str,
        status: &'static str,
        documentation_url: &'static str,
        open_url: String,
        target: &'a str,
        family: &'static str,
        instance: &'a str,
        bot: BotOutput<'a>,
        integration: IntegrationOutput<'a>,
        service: ServiceOutput,
        mapping: MappingOutput,
    }
    #[derive(serde::Serialize)]
    struct BotOutput<'a> {
        id: i64,
        username: &'a str,
        name: &'a str,
    }
    #[derive(serde::Serialize)]
    struct IntegrationOutput<'a> {
        kind: &'static str,
        action: &'static str,
        version: &'a str,
    }
    #[derive(serde::Serialize)]
    struct ServiceOutput {
        kind: &'static str,
        action: &'static str,
        ready: bool,
    }
    #[derive(serde::Serialize)]
    struct MappingOutput {
        source: &'static str,
        action: &'static str,
    }
    let output = ResultOutput {
        protocol_version: AGENTS_PROTOCOL_VERSION,
        ok: true,
        action: "agents.setup",
        status: if outcome.ready { "ready" } else { "configured" },
        documentation_url: AGENTS_DOCUMENTATION_URL,
        open_url: format!("in://user/{}", bot.id),
        target: descriptor.id,
        family: "gateway",
        instance,
        bot: BotOutput {
            id: bot.id,
            username: &bot.username,
            name: &bot.name,
        },
        integration: IntegrationOutput {
            kind: "plugin",
            action: outcome.integration_action,
            version: &outcome.integration_version,
        },
        service: ServiceOutput {
            kind: "gateway",
            action: outcome.service_action,
            ready: outcome.ready,
        },
        mapping: MappingOutput {
            source: "inline_config",
            action: "upserted",
        },
    };
    if json {
        print_setup_result(&output, json_format, app_protocol)?;
    } else {
        println!("{} is configured in Inline.", descriptor.display_name);
        println!("Bot: @{} ({})", bot.username, bot.id);
        println!("Open: in://user/{}", bot.id);
        println!("Integration: {}", outcome.integration_action);
        println!("Gateway: {}", outcome.service_action);
        if !outcome.ready {
            println!("Restart required before the bot is ready.");
        }
    }
    Ok(())
}

fn print_setup_result<T: serde::Serialize>(
    result: &T,
    json_format: JsonFormat,
    app_protocol: Option<u32>,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(protocol_version) = app_protocol {
        println!("{}", app_result_event_line(protocol_version, result)?);
        io::stdout().flush()?;
    } else {
        crate::output::print_json(result, json_format)?;
    }
    Ok(())
}

fn app_result_event_line<T: serde::Serialize>(
    protocol_version: u32,
    result: &T,
) -> Result<String, serde_json::Error> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct ResultEvent<'a, T> {
        protocol_version: u32,
        event: &'static str,
        result: &'a T,
    }
    serde_json::to_string(&ResultEvent {
        protocol_version,
        event: "result",
        result,
    })
}

fn validate_target_args(
    args: &AgentsSetupArgs,
    family: TargetFamily,
) -> Result<(), Box<dyn std::error::Error>> {
    match family {
        TargetFamily::Bridge => {
            if args.profile.is_some()
                || args.bot_id.is_some()
                || args.bot_username.is_some()
                || args.replace
            {
                return Err(cli_error(
                    "unsupported_option",
                    "--profile, --bot-id, --bot-username, and --replace are supported only for Hermes/OpenClaw targets",
                )
                .into());
            }
            if matches!(args.access, AccessMode::Open | AccessMode::Disabled) {
                return Err(cli_error(
                    "unsupported_option",
                    "Codex/ACP bridge targets support only owner or allowlist access",
                )
                .into());
            }
        }
        TargetFamily::Gateway => {
            if args.folder.is_some() {
                return Err(cli_error(
                    "unsupported_option",
                    "--folder is supported only for Codex/ACP bridge targets",
                )
                .into());
            }
        }
    }
    Ok(())
}

pub(super) fn cli_error(code: &'static str, message: impl Into<String>) -> CliError {
    CliError {
        code,
        message: message.into(),
        hint: Some(format!(
            "See the agent setup guide: {AGENTS_DOCUMENTATION_URL}"
        )),
        examples: Vec::new(),
    }
}

fn print_dry_run(
    resolved: &ResolvedSetup,
    json: bool,
    json_format: JsonFormat,
    app_protocol: Option<u32>,
) -> Result<(), Box<dyn std::error::Error>> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct DryRun<'a> {
        protocol_version: u32,
        ok: bool,
        action: &'static str,
        status: &'static str,
        documentation_url: &'static str,
        target: &'a str,
        installed: bool,
    }
    let result = DryRun {
        protocol_version: AGENTS_PROTOCOL_VERSION,
        ok: true,
        action: "agents.setup",
        status: "planned",
        documentation_url: AGENTS_DOCUMENTATION_URL,
        target: resolved.installed.descriptor.id,
        installed: true,
    };
    if json {
        print_setup_result(&result, json_format, app_protocol)?;
    } else {
        println!(
            "{} is installed and can be set up.",
            resolved.installed.descriptor.display_name
        );
        println!("Dry run: no changes were made.");
    }
    Ok(())
}

#[cfg(test)]
mod app_protocol_tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn verbose_is_global_repeatable_and_retry_keeps_mutation_constraints() {
        let cli = crate::Cli::try_parse_from([
            "inline",
            "--verbose",
            "agents",
            "setup",
            "--verbose",
            "--target",
            "codex",
            "--folder",
            "/tmp/Mo's project",
            "--allow-user",
            "42",
            "--no-install",
            "--no-restart",
            "--dry-run",
        ])
        .unwrap();
        let flags = crate::detect_global_flags(
            &["inline", "--verbose", "agents", "setup", "--verbose"].map(std::ffi::OsString::from),
        );
        assert_eq!(flags.verbose.max(cli.verbose), 2);
        let crate::Command::Agents {
            command: AgentsCommand::Setup(args),
        } = cli.command
        else {
            panic!("setup");
        };
        let retry = setup_retry_command(&args);
        for flag in [
            "--allow-user '42'",
            "--no-install",
            "--no-restart",
            "--dry-run",
        ] {
            assert!(retry.contains(flag));
        }
        if cfg!(unix) {
            assert!(retry.contains("'/tmp/Mo'\\''s project'"));
        }
        assert!(!retry.contains("--replace"));
        assert!(matches!(
            crate::Cli::try_parse_from(["inline", "-v"])
                .err()
                .unwrap()
                .kind(),
            clap::error::ErrorKind::DisplayVersion
        ));
    }

    #[test]
    fn failure_ledger_retains_actual_phase_and_completed_changes_without_app_protocol() {
        let progress = SetupProgressReporter::new(None, false);
        progress.started("preflight");
        progress.completed("preflight", "ready");
        assert!(progress.changes.borrow().is_empty());
        progress.started("integration");
        progress.completed("integration", "ready");
        progress.started("bot");
        assert_eq!(progress.phase.get(), "bot");
        assert_eq!(*progress.changes.borrow(), vec!["integration_ready"]);
    }

    #[test]
    fn discovery_protocol_lists_every_target_without_local_paths() {
        let installed = vec![InstalledTarget {
            descriptor: AgentTarget::Codex.descriptor(),
            executable: PathBuf::from("/private/example/codex"),
        }];
        let output = discovery_output(&installed);
        let json = serde_json::to_string(&output).expect("serialize discovery");

        assert_eq!(output.protocol_version, 1);
        assert_eq!(output.action, "agents.discover");
        assert_eq!(output.targets.len(), catalog::TARGETS.len());
        assert!(
            output
                .targets
                .iter()
                .any(|target| target.id == "codex" && target.installed)
        );
        assert!(!json.contains("/private/example"));
    }

    #[test]
    fn setup_progress_is_token_free_fixed_code_ndjson() {
        let line = app_progress_event_line(1, "phase.completed", "bot", Some("reused"))
            .expect("serialize progress event");
        let value: serde_json::Value = serde_json::from_str(&line).expect("decode progress event");

        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["event"], "phase.completed");
        assert_eq!(value["phase"], "bot");
        assert_eq!(value["outcome"], "reused");
        assert_eq!(value["message"], "Existing Inline bot reused.");
        assert!(!line.contains("token"));
        assert!(!line.contains("/private/"));
    }

    #[test]
    fn service_progress_exposes_the_wait_to_native_hosts() {
        let line = app_progress_event_line(1, "phase.started", "service", None)
            .expect("serialize progress event");
        let value: serde_json::Value = serde_json::from_str(&line).expect("decode progress event");

        assert_eq!(
            value["message"],
            "Starting the local bridge service; this can take up to 90 seconds..."
        );
        assert_eq!(value["timeoutSeconds"], 90);
    }

    #[test]
    fn setup_result_is_the_terminal_event() {
        let result = serde_json::json!({"ok": true, "action": "agents.setup"});
        let line = app_result_event_line(1, &result).expect("serialize result event");
        let value: serde_json::Value = serde_json::from_str(&line).expect("decode result event");

        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["event"], "result");
        assert_eq!(value["result"]["action"], "agents.setup");
    }
}
