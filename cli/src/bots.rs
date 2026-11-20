//! Owner management for bots: profile, photo, avatar, token, settings, and access.
//!
//! Settings and access commands take one bot, several (`--bot-user-id 1,2`),
//! or every bot you own (`--all`, `--filter`), so an owner with many bots, or
//! an agent acting for them, changes them all in one command. Those paths box
//! their futures so `handle_bot_management`'s state machine stays small.

use inline_protocol::proto;
use serde::Serialize;

use crate::attachments::prepare_photo_upload;
use crate::auth::AuthStore;
use crate::config::Config;
use crate::errors::{CliError, ReportedExit};
use crate::output::{self, JsonFormat, terminal_text, user_display_name};
use crate::validation::validate_positive_id_arg;
use crate::{
    AuthenticatedRealtime, BotsAccessCommand, BotsCommand, confirm_action,
    connect_authenticated_realtime,
};

type CliResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

/// Which bots a settings or access command acts on.
#[derive(clap::Args, Clone, Debug, Default)]
pub(crate) struct BotSelectionArgs {
    #[arg(
        long = "bot-user-id",
        value_name = "ID",
        value_delimiter = ',',
        help = "Bot user id; comma-separate or repeat it for several bots"
    )]
    pub(crate) bot_user_ids: Vec<i64>,

    #[arg(long, conflicts_with = "bot_user_ids", help = "Every bot you own")]
    pub(crate) all: bool,

    #[arg(
        long,
        short = 'f',
        value_name = "TEXT",
        conflicts_with = "bot_user_ids",
        help = "Only your bots whose name or username contains this text"
    )]
    pub(crate) filter: Option<String>,

    #[arg(
        long,
        conflicts_with = "bot_user_ids",
        help = "Also include bots you manage as an admin"
    )]
    pub(crate) include_managed: bool,

    #[arg(
        long,
        value_name = "ID",
        value_delimiter = ',',
        conflicts_with = "bot_user_ids",
        help = "Leave out these bot user ids (comma-separated)"
    )]
    pub(crate) except: Vec<i64>,
}

impl BotSelectionArgs {
    /// No bot was named, so listing commands show every bot you own.
    fn is_empty(&self) -> bool {
        self.bot_user_ids.is_empty()
            && !self.all
            && self.filter.is_none()
            && !self.include_managed
            && self.except.is_empty()
    }

    /// The original single-bot form, whose output stays as it was.
    fn single(&self) -> Option<i64> {
        match self.bot_user_ids.as_slice() {
            [id] => Some(*id),
            _ => None,
        }
    }

    fn require_single(&self, purpose: &str) -> CliResult<i64> {
        match self.single() {
            Some(id) => Ok(validate_positive_id_arg("--bot-user-id", id)?),
            None => Err(CliError::invalid_args(format!(
                "{purpose} needs exactly one --bot-user-id."
            ))
            .into()),
        }
    }

    fn require_some(&self) -> CliResult {
        if self.is_empty() {
            return Err(CliError::invalid_args(
                "Choose bots with --bot-user-id ID[,ID...], --all, or --filter TEXT.",
            )
            .into());
        }
        Ok(())
    }
}

/// A bot a bulk command acts on. `user` is absent for an id that isn't among
/// the bots you own or manage; the server still decides whether you may change it.
struct TargetBot {
    id: i64,
    user: Option<proto::User>,
}

impl TargetBot {
    fn label(&self) -> String {
        match self.user.as_ref() {
            Some(user) => bot_label(user),
            None => format!("bot {}", self.id),
        }
    }
}

/// Resolves a selection to bots, in list order for `--all`/`--filter` and in
/// the given order for ids.
async fn resolve_bots(
    realtime: &mut AuthenticatedRealtime,
    selection: &BotSelectionArgs,
) -> CliResult<Vec<TargetBot>> {
    if !selection.bot_user_ids.is_empty() {
        let mut ids: Vec<i64> = Vec::with_capacity(selection.bot_user_ids.len());
        for id in &selection.bot_user_ids {
            let id = validate_positive_id_arg("--bot-user-id", *id)?;
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        let known = realtime
            .call(proto::ListBotsInput {
                include_managed: Some(true),
            })
            .await?
            .bots;
        return Ok(ids
            .into_iter()
            .map(|id| TargetBot {
                id,
                user: known.iter().find(|bot| bot.id == id).cloned(),
            })
            .collect());
    }
    let mut except = Vec::with_capacity(selection.except.len());
    for id in &selection.except {
        except.push(validate_positive_id_arg("--except", *id)?);
    }
    let needle = selection
        .filter
        .as_deref()
        .map(str::trim)
        .filter(|filter| !filter.is_empty())
        .map(str::to_lowercase);
    let bots = realtime
        .call(proto::ListBotsInput {
            include_managed: selection.include_managed.then_some(true),
        })
        .await?
        .bots;
    Ok(bots
        .into_iter()
        .filter(|bot| !except.contains(&bot.id))
        .filter(|bot| {
            needle
                .as_deref()
                .is_none_or(|needle| crate::proto_user_matches_filter(bot, needle))
        })
        .map(|bot| TargetBot {
            id: bot.id,
            user: Some(bot),
        })
        .collect())
}

fn no_bots_matched(selection: &BotSelectionArgs) -> Box<dyn std::error::Error> {
    let message = match selection.filter.as_deref() {
        Some(filter) => format!(
            "No bots you own match \"{}\". Run `inline bots list` to see them.",
            terminal_text(filter)
        ),
        None => "No bots matched. Run `inline bots list` to see your bots.".to_string(),
    };
    CliError::invalid_args(message).into()
}

/// "only you", "everyone", or "1 space, 2 people", matching the apps' Shared With.
fn shared_with_summary(grants: &[proto::AgentGrant], open_to_everyone: bool) -> String {
    use proto::access_subject::Subject;
    if open_to_everyone {
        return "everyone".to_string();
    }
    let (mut people, mut spaces, mut groups) = (0, 0, 0);
    for grant in grants {
        match grant
            .subject
            .as_ref()
            .and_then(|subject| subject.subject.as_ref())
        {
            Some(Subject::SpaceId(_)) => spaces += 1,
            Some(Subject::GroupId(_)) => groups += 1,
            Some(Subject::UserId(_)) | None => people += 1,
        }
    }
    let count = |count: usize, one: &str, many: &str| match count {
        0 => None,
        1 => Some(format!("1 {one}")),
        count => Some(format!("{count} {many}")),
    };
    let parts: Vec<String> = [
        count(spaces, "space", "spaces"),
        count(groups, "group", "groups"),
        count(people, "person", "people"),
    ]
    .into_iter()
    .flatten()
    .collect();
    if parts.is_empty() {
        "only you".to_string()
    } else {
        parts.join(", ")
    }
}

/// One row of `inline bots settings` / `inline bots access list` for many bots.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BotOverviewRow {
    pub(crate) bot_user_id: i64,
    pub(crate) name: String,
    pub(crate) username: Option<String>,
    /// friendly, detailed, or unset (the agent's default, Detailed).
    pub(crate) output_mode: Option<&'static str>,
    pub(crate) open_to_everyone: Option<bool>,
    /// "only you", "everyone", or counts such as "1 space, 2 people".
    pub(crate) shared_with: Option<String>,
    pub(crate) grant_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BotOverviewOutput {
    bots: Vec<BotOverviewRow>,
}

async fn bot_overview_row(realtime: &mut AuthenticatedRealtime, bot: &TargetBot) -> BotOverviewRow {
    let (name, username) = match bot.user.as_ref() {
        Some(user) => (
            user_display_name(user),
            user.username
                .clone()
                .filter(|username| !username.is_empty()),
        ),
        None => (format!("bot {}", bot.id), None),
    };
    let mut row = BotOverviewRow {
        bot_user_id: bot.id,
        name,
        username,
        output_mode: None,
        open_to_everyone: None,
        shared_with: None,
        grant_count: None,
        error: None,
    };
    let settings = match read_agent_settings(realtime, bot.id).await {
        Ok(settings) => settings.unwrap_or_default(),
        Err(error) => {
            row.error = Some(error.to_string());
            return row;
        }
    };
    row.output_mode = Some(output_mode_label(settings.default_output_mode));
    row.open_to_everyone = Some(settings.open_to_everyone);
    match realtime
        .call(proto::ListAgentGrantsInput {
            bot_user_id: bot.id,
            include_all_subjects: Some(true),
        })
        .await
    {
        Ok(payload) => {
            row.shared_with = Some(shared_with_summary(
                &payload.grants,
                settings.open_to_everyone,
            ));
            row.grant_count = Some(payload.grants.len());
        }
        Err(error) => row.error = Some(error.to_string()),
    }
    row
}

/// Output mode and who can message each selected bot (every bot you own when
/// none is named).
async fn print_bot_overview(
    realtime: &mut AuthenticatedRealtime,
    selection: &BotSelectionArgs,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    let bots = resolve_bots(realtime, selection).await?;
    if bots.is_empty() && !selection.is_empty() {
        return Err(no_bots_matched(selection));
    }
    announce_bots(bots.len(), json);
    let mut rows = Vec::with_capacity(bots.len());
    for bot in &bots {
        rows.push(bot_overview_row(realtime, bot).await);
    }
    if json {
        return Ok(output::print_json(
            &BotOverviewOutput { bots: rows },
            json_format,
        )?);
    }
    if rows.is_empty() {
        println!("You don't own any bots yet. Create one with `inline bots create`.");
        return Ok(());
    }
    output::print_bot_overview(&rows);
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum BulkStatus {
    Changed,
    WouldChange,
    Unchanged,
    Failed,
}

impl BulkStatus {
    fn label(self) -> &'static str {
        match self {
            Self::Changed => "changed",
            Self::WouldChange => "would change",
            Self::Unchanged => "unchanged",
            Self::Failed => "failed",
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BulkResult {
    bot_user_id: i64,
    name: Option<String>,
    username: Option<String>,
    #[serde(skip)]
    label: String,
    status: BulkStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    from: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl BulkResult {
    fn failed(bot: &TargetBot, error: impl ToString) -> Self {
        Self {
            bot_user_id: bot.id,
            name: bot.user.as_ref().map(user_display_name),
            username: bot.user.as_ref().and_then(|user| user.username.clone()),
            label: bot.label(),
            status: BulkStatus::Failed,
            from: None,
            to: None,
            error: Some(error.to_string()),
        }
    }

    fn compared(bot: &TargetBot, from: String, to: String, dry_run: bool) -> Self {
        let status = if from == to {
            BulkStatus::Unchanged
        } else if dry_run {
            BulkStatus::WouldChange
        } else {
            BulkStatus::Changed
        };
        Self {
            bot_user_id: bot.id,
            name: bot.user.as_ref().map(user_display_name),
            username: bot.user.as_ref().and_then(|user| user.username.clone()),
            label: bot.label(),
            status,
            from: Some(from),
            to: Some(to),
            error: None,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BulkOutput {
    /// output_mode, open, close, grant, or revoke.
    action: &'static str,
    title: String,
    dry_run: bool,
    changed: usize,
    would_change: usize,
    unchanged: usize,
    failed: usize,
    results: Vec<BulkResult>,
}

/// JSON keeps "unset" for a cleared output mode, as `bots get` does; people
/// read it as the `default` they pass to `--output-mode`.
fn human_value(value: &str) -> &str {
    if value == "unset" { "default" } else { value }
}

/// "Checking 21 bots…" on a terminal, so a long sequential run doesn't look stuck.
fn announce_bots(count: usize, json: bool) {
    use std::io::IsTerminal;
    if !json && count > 5 && std::io::stderr().is_terminal() {
        eprintln!("Checking {count} bots…");
    }
}

/// Prints a bulk change, and exits 1 after printing when any bot failed.
fn finish_bulk(
    action: &'static str,
    title: String,
    dry_run: bool,
    results: Vec<BulkResult>,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    let count = |status: BulkStatus| results.iter().filter(|r| r.status == status).count();
    let output = BulkOutput {
        changed: count(BulkStatus::Changed),
        would_change: count(BulkStatus::WouldChange),
        unchanged: count(BulkStatus::Unchanged),
        failed: count(BulkStatus::Failed),
        action,
        title,
        dry_run,
        results,
    };
    if json {
        output::print_json(&output, json_format)?;
    } else {
        let bots = if output.results.len() == 1 {
            "bot"
        } else {
            "bots"
        };
        println!(
            "{}{} ({} {bots}):",
            if dry_run { "Dry run: " } else { "" },
            output.title,
            output.results.len()
        );
        for result in &output.results {
            let detail = match (&result.error, &result.from, &result.to) {
                (Some(error), _, _) => terminal_text(error).into_owned(),
                (None, Some(from), Some(_)) if result.status == BulkStatus::Unchanged => {
                    format!("already {}", human_value(from))
                }
                (None, Some(from), Some(to)) => {
                    format!("{} → {}", human_value(from), human_value(to))
                }
                _ => String::new(),
            };
            println!(
                "  {:<12}  {}: {detail}",
                result.status.label(),
                result.label
            );
        }
        let mut summary = Vec::new();
        if dry_run {
            summary.push(format!("{} would change", output.would_change));
        } else {
            summary.push(format!("{} changed", output.changed));
        }
        summary.push(format!("{} unchanged", output.unchanged));
        if output.failed > 0 {
            summary.push(format!("{} failed", output.failed));
        }
        println!(
            "{}.{}",
            summary.join(", "),
            if dry_run { " Nothing was changed." } else { "" }
        );
    }
    if output.failed > 0 {
        return Err(ReportedExit(1).into());
    }
    Ok(())
}

/// Sets the default output mode on every selected bot, skipping bots already set.
async fn bulk_output_mode(
    realtime: &mut AuthenticatedRealtime,
    bots: &[TargetBot],
    mode: BotOutputMode,
    dry_run: bool,
) -> Vec<BulkResult> {
    let target = mode.protocol_value() as i32;
    let mut results = Vec::with_capacity(bots.len());
    for bot in bots {
        let current = match read_agent_settings(realtime, bot.id).await {
            Ok(settings) => settings.unwrap_or_default().default_output_mode,
            Err(error) => {
                results.push(BulkResult::failed(bot, error));
                continue;
            }
        };
        let result = BulkResult::compared(
            bot,
            output_mode_label(current).to_string(),
            output_mode_label(target).to_string(),
            dry_run,
        );
        if result.status != BulkStatus::Changed {
            results.push(result);
            continue;
        }
        let update = realtime
            .call(proto::UpdateAgentSettingsInput {
                bot_user_id: bot.id,
                default_output_mode: Some(target),
                open_to_everyone: None,
            })
            .await;
        results.push(match update {
            Ok(payload)
                if payload
                    .settings
                    .as_ref()
                    .is_none_or(|settings| settings.default_output_mode == target) =>
            {
                result
            }
            Ok(_) => BulkResult::failed(bot, "The server didn't apply the change."),
            Err(error) => BulkResult::failed(bot, error),
        });
    }
    results
}

fn open_label(open: bool) -> String {
    if open { "open" } else { "closed" }.to_string()
}

/// Opens or closes every selected bot, skipping bots already that way.
async fn bulk_open_to_everyone(
    realtime: &mut AuthenticatedRealtime,
    bots: &[TargetBot],
    open: bool,
    dry_run: bool,
) -> Vec<BulkResult> {
    let mut results = Vec::with_capacity(bots.len());
    for bot in bots {
        let current = match read_agent_settings(realtime, bot.id).await {
            Ok(settings) => settings.unwrap_or_default().open_to_everyone,
            Err(error) => {
                results.push(BulkResult::failed(bot, error));
                continue;
            }
        };
        let result = BulkResult::compared(bot, open_label(current), open_label(open), dry_run);
        if result.status != BulkStatus::Changed {
            results.push(result);
            continue;
        }
        let update = realtime
            .call(proto::UpdateAgentSettingsInput {
                bot_user_id: bot.id,
                default_output_mode: None,
                open_to_everyone: Some(open),
            })
            .await;
        results.push(match update {
            Ok(payload)
                if payload
                    .settings
                    .as_ref()
                    .is_some_and(|settings| settings.open_to_everyone == open) =>
            {
                result
            }
            // A server that predates the setting accepts the call and changes nothing.
            Ok(_) => BulkResult::failed(
                bot,
                "This server doesn't support opening or closing a bot yet.",
            ),
            Err(error) => BulkResult::failed(bot, error),
        });
    }
    results
}

fn grant_matches(grant: &proto::AgentGrant, subject: &proto::AccessSubject) -> bool {
    use proto::access_subject::Subject;
    match (
        grant
            .subject
            .as_ref()
            .and_then(|value| value.subject.as_ref()),
        subject.subject.as_ref(),
    ) {
        (Some(have), Some(want)) => have == want,
        (None, Some(Subject::UserId(id))) => grant.user_id == *id,
        _ => false,
    }
}

fn sorted_operations(operations: &[i32]) -> Vec<i32> {
    let mut operations = operations.to_vec();
    operations.sort_unstable();
    operations.dedup();
    operations
}

/// Grants (operations given) or revokes (None) one subject's access on every
/// selected bot, skipping bots where it is already so.
async fn bulk_grant(
    realtime: &mut AuthenticatedRealtime,
    bots: &[TargetBot],
    subject: &proto::AccessSubject,
    operations: Option<&[i32]>,
    dry_run: bool,
) -> Vec<BulkResult> {
    let user_id = match subject.subject {
        Some(proto::access_subject::Subject::UserId(id)) => id,
        _ => 0,
    };
    let mut results = Vec::with_capacity(bots.len());
    for bot in bots {
        let existing = match realtime
            .call(proto::ListAgentGrantsInput {
                bot_user_id: bot.id,
                include_all_subjects: Some(true),
            })
            .await
        {
            Ok(payload) => payload
                .grants
                .into_iter()
                .find(|grant| grant_matches(grant, subject)),
            Err(error) => {
                results.push(BulkResult::failed(bot, error));
                continue;
            }
        };
        let from = existing
            .as_ref()
            .map(|grant| operations_label(&sorted_operations(&grant.operations)))
            .unwrap_or_else(|| "no access".to_string());
        let to = operations
            .map(|operations| operations_label(&sorted_operations(operations)))
            .unwrap_or_else(|| "no access".to_string());
        let result = BulkResult::compared(bot, from, to, dry_run);
        if result.status != BulkStatus::Changed {
            results.push(result);
            continue;
        }
        let call = match operations {
            Some(operations) => realtime
                .call(proto::SetAgentGrantInput {
                    bot_user_id: bot.id,
                    user_id,
                    operations: operations.to_vec(),
                    subject: Some(subject.clone()),
                })
                .await
                .map(|_| ()),
            None => realtime
                .call(proto::DeleteAgentGrantInput {
                    bot_user_id: bot.id,
                    user_id,
                    subject: Some(subject.clone()),
                })
                .await
                .map(|_| ()),
        };
        results.push(match call {
            Ok(()) => result,
            Err(error) => BulkResult::failed(bot, error),
        });
    }
    results
}

/// Resolves a bulk selection, failing when it names no bots.
async fn resolve_bulk_targets(
    realtime: &mut AuthenticatedRealtime,
    selection: &BotSelectionArgs,
    json: bool,
) -> CliResult<Vec<TargetBot>> {
    selection.require_some()?;
    let bots = resolve_bots(realtime, selection).await?;
    if bots.is_empty() {
        return Err(no_bots_matched(selection));
    }
    announce_bots(bots.len(), json);
    Ok(bots)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum BotOutputMode {
    /// Progress, tool calls, and technical detail.
    Detailed,
    /// No progress or tool chatter, and a plain-language answer.
    Friendly,
    /// Clear the selected preference for this bot or thread.
    Default,
}

impl BotOutputMode {
    /// An explicit reset sends UNSPECIFIED. Omitting the flag only reads settings.
    fn protocol_value(self) -> proto::AgentOutputMode {
        match self {
            Self::Detailed => proto::AgentOutputMode::Detailed,
            Self::Friendly => proto::AgentOutputMode::Friendly,
            Self::Default => proto::AgentOutputMode::Unspecified,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub(crate) enum BotGrantOperation {
    /// Start work.
    Invoke,
    /// Steer, queue, stop, pause, and resume work.
    Steer,
    /// Answer approvals as a delegate of the owner.
    Approve,
    /// Change the bot's settings.
    Configure,
}

impl BotGrantOperation {
    fn protocol_value(self) -> proto::AgentGrantOperation {
        match self {
            Self::Invoke => proto::AgentGrantOperation::Invoke,
            Self::Steer => proto::AgentGrantOperation::Steer,
            Self::Approve => proto::AgentGrantOperation::Approve,
            Self::Configure => proto::AgentGrantOperation::Configure,
        }
    }
}

/// Operations a new grant gets when none are given, matching the apps.
const DEFAULT_GRANT_OPERATIONS: [BotGrantOperation; 2] =
    [BotGrantOperation::Invoke, BotGrantOperation::Steer];

fn grant_operations(requested: &[BotGrantOperation]) -> Vec<i32> {
    let requested = if requested.is_empty() {
        &DEFAULT_GRANT_OPERATIONS[..]
    } else {
        requested
    };
    let mut operations: Vec<i32> = Vec::with_capacity(requested.len());
    for operation in requested {
        let value = operation.protocol_value() as i32;
        if !operations.contains(&value) {
            operations.push(value);
        }
    }
    operations
}

fn output_mode_label(value: i32) -> &'static str {
    match proto::AgentOutputMode::try_from(value) {
        Ok(proto::AgentOutputMode::Friendly) => "friendly",
        Ok(proto::AgentOutputMode::Detailed) => "detailed",
        Ok(proto::AgentOutputMode::Unspecified) => "unset",
        Err(_) => "unknown",
    }
}

fn operations_label(operations: &[i32]) -> String {
    let labels: Vec<&str> = operations
        .iter()
        .map(|value| match proto::AgentGrantOperation::try_from(*value) {
            Ok(proto::AgentGrantOperation::Invoke) => "invoke",
            Ok(proto::AgentGrantOperation::Steer) => "steer",
            Ok(proto::AgentGrantOperation::Approve) => "approve",
            Ok(proto::AgentGrantOperation::Configure) => "configure",
            _ => "unknown",
        })
        .collect();
    if labels.is_empty() {
        "-".to_string()
    } else if labels.contains(&"configure") {
        format!("admin ({})", labels.join(", "))
    } else {
        labels.join(", ")
    }
}

fn bot_label(bot: &proto::User) -> String {
    let name = user_display_name(bot);
    match bot.username.as_deref().filter(|value| !value.is_empty()) {
        Some(username) => format!("{} (@{username}, id {})", terminal_text(&name), bot.id),
        None => format!("{} (id {})", terminal_text(&name), bot.id),
    }
}

/// The bot's agent settings. Servers without the settings read mirror the
/// default output mode on the bot's runtime; absent both, it is the default.
async fn read_agent_settings(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
) -> CliResult<Option<proto::AgentSettings>> {
    match realtime
        .call(proto::GetAgentSettingsInput { bot_user_id })
        .await
    {
        Ok(payload) => Ok(payload.settings),
        Err(_) => {
            let runtime = realtime
                .call(proto::GetAgentRuntimeInput { bot_user_id })
                .await?
                .runtime;
            Ok(Some(proto::AgentSettings {
                bot_user_id,
                default_output_mode: runtime
                    .map(|runtime| runtime.default_output_mode)
                    .unwrap_or_default(),
                ..Default::default()
            }))
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadOutputModeOutput {
    bot_user_id: i64,
    chat_id: i64,
    /// Absent when the thread uses the bot's default.
    output_mode: Option<&'static str>,
    default_output_mode: &'static str,
}

fn chat_peer(chat_id: i64) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id,
        })),
    }
}

/// The thread's override for one bot, if any.
async fn read_thread_output_mode(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
    chat_id: i64,
) -> CliResult<Option<i32>> {
    let payload = realtime
        .call(proto::GetAgentParticipationsInput {
            peer_id: Some(chat_peer(chat_id)),
        })
        .await?;
    Ok(payload
        .participations
        .into_iter()
        .find(|participation| participation.bot_user_id == bot_user_id)
        .and_then(|participation| participation.output_mode)
        .filter(|mode| *mode != proto::AgentOutputMode::Unspecified as i32))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BotDetailsOutput {
    bot: proto::User,
    settings: Option<proto::AgentSettings>,
    grants: Vec<proto::AgentGrant>,
}

async fn find_owned_bot(
    realtime: &mut AuthenticatedRealtime,
    bot_user_id: i64,
) -> CliResult<proto::User> {
    let payload = realtime
        .call(proto::ListBotsInput {
            include_managed: Some(true),
        })
        .await?;
    payload
        .bots
        .into_iter()
        .find(|bot| bot.id == bot_user_id)
        .ok_or_else(|| {
            CliError::invalid_args(format!(
                "No bot you own has user id {bot_user_id}. Run `inline bots list` to see your bots."
            ))
            .into()
        })
}

fn print_profile_result(
    payload: &proto::UpdateBotProfileResult,
    action: &str,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    if json {
        output::print_json(payload, json_format)?;
    } else if let Some(bot) = payload.bot.as_ref() {
        println!("{action} for {}.", bot_label(bot));
    } else {
        println!("{action}.");
    }
    Ok(())
}

fn print_grants(grants: &[proto::AgentGrant], open_to_everyone: bool) {
    if grants.is_empty() {
        if !open_to_everyone {
            println!("Access: owner only");
        }
        return;
    }
    println!("Access:");
    for grant in grants {
        println!(
            "  {}: {}",
            subject_label(grant.subject.as_ref(), grant.user_id),
            operations_label(&grant.operations)
        );
    }
}

fn subject_label(subject: Option<&proto::AccessSubject>, user_id: i64) -> String {
    use proto::access_subject::Subject;
    match subject.and_then(|subject| subject.subject.clone()) {
        Some(Subject::SpaceId(id)) => format!("space {id}"),
        Some(Subject::GroupId(id)) => format!("group {id}"),
        Some(Subject::UserId(id)) => format!("user {id}"),
        None => format!("user {user_id}"),
    }
}

/// The grant's subject from `--user-id`, `--space-id` or `--group-id` (exactly one).
fn access_subject(args: &crate::BotsAccessSubjectArgs) -> CliResult<proto::AccessSubject> {
    use proto::access_subject::Subject;
    let subject = match (args.user_id, args.space_id, args.group_id) {
        (Some(id), None, None) => Subject::UserId(validate_positive_id_arg("--user-id", id)?),
        (None, Some(id), None) => Subject::SpaceId(validate_positive_id_arg("--space-id", id)?),
        (None, None, Some(id)) => Subject::GroupId(validate_positive_id_arg("--group-id", id)?),
        _ => {
            return Err(CliError::invalid_args(
                "Pass exactly one of --user-id, --space-id or --group-id.",
            )
            .into());
        }
    };
    Ok(proto::AccessSubject {
        subject: Some(subject),
    })
}

/// Opens a bot to everyone on Inline, or limits it to its owner and access list again.
async fn set_open_to_everyone(
    config: &Config,
    auth_store: &AuthStore,
    bot_user_id: i64,
    open: bool,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    let bot_user_id = validate_positive_id_arg("--bot-user-id", bot_user_id)?;
    let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
    let payload = realtime
        .call(proto::UpdateAgentSettingsInput {
            bot_user_id,
            default_output_mode: None,
            open_to_everyone: Some(open),
        })
        .await?;
    if json {
        return Ok(output::print_json(&payload, json_format)?);
    }
    // A server that predates the setting accepts the call and changes nothing.
    let applied = payload
        .settings
        .as_ref()
        .is_some_and(|settings| settings.open_to_everyone == open);
    if !applied {
        return Err(CliError::invalid_args(
            "This server doesn't support opening a bot to everyone yet.".to_string(),
        )
        .into());
    }
    if open {
        println!("Anyone on Inline can now message bot {bot_user_id}.");
    } else {
        println!("Only you and the people on its access list can message bot {bot_user_id}.");
    }
    Ok(())
}

/// `access open` / `access close`: the original one-bot form, or a bulk change.
async fn open_or_close(
    config: &Config,
    auth_store: &AuthStore,
    args: crate::BotsBulkArgs,
    open: bool,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    if let Some(bot_user_id) = args.selection.single().filter(|_| !args.dry_run) {
        return set_open_to_everyone(config, auth_store, bot_user_id, open, json, json_format)
            .await;
    }
    let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
    let bots = Box::pin(resolve_bulk_targets(&mut realtime, &args.selection, json)).await?;
    let results = Box::pin(bulk_open_to_everyone(
        &mut realtime,
        &bots,
        open,
        args.dry_run,
    ))
    .await;
    let action = if open {
        "Open to everyone on Inline"
    } else {
        "Limit to you and the access list"
    };
    finish_bulk(
        if open { "open" } else { "close" },
        action.to_string(),
        args.dry_run,
        results,
        json,
        json_format,
    )
}

fn grant_args_operations(args: &crate::BotsAccessGrantArgs) -> Vec<i32> {
    if args.admin {
        crate::bot_sharing::ADMIN_OPERATIONS
            .iter()
            .map(|operation| *operation as i32)
            .collect()
    } else {
        grant_operations(&args.operations)
    }
}

/// Handles every bots subcommand except list, create, and reveal-token.
pub(crate) async fn handle_bot_management(
    command: BotsCommand,
    config: &Config,
    auth_store: &AuthStore,
    json: bool,
    json_format: JsonFormat,
) -> CliResult {
    match command {
        BotsCommand::List(_) | BotsCommand::Create(_) | BotsCommand::RevealToken(_) => {
            unreachable!("handled in main")
        }
        BotsCommand::Get(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let bot = find_owned_bot(&mut realtime, bot_user_id).await?;
            let settings = read_agent_settings(&mut realtime, bot_user_id).await?;
            let grants = realtime
                .call(proto::ListAgentGrantsInput {
                    bot_user_id,
                    include_all_subjects: Some(true),
                })
                .await?
                .grants;
            if json {
                output::print_json(
                    &BotDetailsOutput {
                        bot,
                        settings,
                        grants,
                    },
                    json_format,
                )?;
            } else {
                println!("Bot: {}", bot_label(&bot));
                let photo = bot
                    .profile_photo
                    .as_ref()
                    .is_some_and(|photo| photo.photo_id.is_some() || photo.cdn_url.is_some());
                println!("Photo: {}", if photo { "set" } else { "none" });
                match bot.bot_avatar.as_ref() {
                    Some(avatar) => println!("Avatar: {}", terminal_text(&avatar.display_name)),
                    None => println!("Avatar: none"),
                }
                let mode = settings
                    .as_ref()
                    .map(|settings| settings.default_output_mode)
                    .unwrap_or_default();
                println!("Output mode: {}", output_mode_label(mode));
                let open = settings
                    .as_ref()
                    .is_some_and(|settings| settings.open_to_everyone);
                if open {
                    println!("Anyone on Inline can message this bot.");
                }
                print_grants(&grants, open);
            }
        }
        BotsCommand::Update(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let name = args
                .name
                .as_deref()
                .map(str::trim)
                .map(|name| {
                    if name.is_empty() {
                        Err(CliError::invalid_args("Bot name cannot be empty"))
                    } else {
                        Ok(name.to_string())
                    }
                })
                .transpose()?;
            let username = args
                .username
                .as_deref()
                .map(|username| username.trim().trim_start_matches('@'))
                .map(|username| {
                    if username.is_empty() {
                        Err(CliError::invalid_args("Bot username cannot be empty"))
                    } else if !username.to_lowercase().ends_with("bot") {
                        Err(CliError::invalid_args("Bot username must end with \"bot\""))
                    } else {
                        Ok(username.to_string())
                    }
                })
                .transpose()?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name,
                    photo_file_unique_id: None,
                    username,
                })
                .await?;
            print_profile_result(&payload, "Updated profile", json, json_format)?;
        }
        BotsCommand::SetPhoto(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let upload_input = prepare_photo_upload(&args.file)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            if !json {
                println!(
                    "Uploading {}...",
                    terminal_text(&args.file.display().to_string())
                );
            }
            let upload = realtime.upload(upload_input).await?;
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name: None,
                    photo_file_unique_id: Some(upload.file_unique_id),
                    username: None,
                })
                .await?;
            print_profile_result(&payload, "Set photo", json, json_format)?;
        }
        BotsCommand::RemovePhoto(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            // An empty file id clears the photo, as the apps do.
            let payload = realtime
                .call(proto::UpdateBotProfileInput {
                    bot_user_id,
                    name: None,
                    photo_file_unique_id: Some(String::new()),
                    username: None,
                })
                .await?;
            print_profile_result(&payload, "Removed photo", json, json_format)?;
        }
        BotsCommand::ClearAvatar(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::ClearBotAvatarInput { bot_user_id })
                .await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else if let Some(bot) = payload.bot.as_ref() {
                println!("Cleared avatar for {}.", bot_label(bot));
            } else {
                println!("Cleared avatar.");
            }
        }
        BotsCommand::RotateToken(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            if json && !args.yes {
                return Err(CliError::confirmation_required().into());
            }
            if !confirm_action(
                &format!(
                    "Rotate the token for bot {bot_user_id}? The current token stops working."
                ),
                args.yes,
            )? {
                println!("Cancelled.");
                return Ok(());
            }
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime
                .call(proto::RotateBotTokenInput { bot_user_id })
                .await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else {
                println!("{}", payload.token);
            }
        }
        BotsCommand::Delete(args) => {
            let bot_user_id = validate_positive_id_arg("--bot-user-id", args.bot_user_id)?;
            if json && !args.yes {
                return Err(CliError::confirmation_required().into());
            }
            if !confirm_action(
                &format!("Delete bot {bot_user_id}? Its token stops working."),
                args.yes,
            )? {
                println!("Cancelled.");
                return Ok(());
            }
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            let payload = realtime.call(proto::DeleteBotInput { bot_user_id }).await?;
            if json {
                output::print_json(&payload, json_format)?;
            } else {
                println!("Deleted bot {}.", payload.bot_user_id);
            }
        }
        BotsCommand::Settings(args) => {
            let chat_id = args
                .chat_id
                .map(|chat_id| validate_positive_id_arg("--chat-id", chat_id))
                .transpose()?;
            let single = if chat_id.is_some() {
                Some(args.selection.require_single("--chat-id")?)
            } else {
                args.selection
                    .single()
                    .filter(|_| !args.dry_run)
                    .map(|id| validate_positive_id_arg("--bot-user-id", id))
                    .transpose()?
            };
            let Some(bot_user_id) = single else {
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let Some(mode) = args.output_mode else {
                    if args.dry_run {
                        return Err(CliError::invalid_args(
                            "--dry-run needs --output-mode to preview.",
                        )
                        .into());
                    }
                    return Box::pin(print_bot_overview(
                        &mut realtime,
                        &args.selection,
                        json,
                        json_format,
                    ))
                    .await;
                };
                let bots =
                    Box::pin(resolve_bulk_targets(&mut realtime, &args.selection, json)).await?;
                let results =
                    Box::pin(bulk_output_mode(&mut realtime, &bots, mode, args.dry_run)).await;
                return finish_bulk(
                    "output_mode",
                    format!(
                        "Output mode → {}",
                        human_value(output_mode_label(mode.protocol_value() as i32))
                    ),
                    args.dry_run,
                    results,
                    json,
                    json_format,
                );
            };
            let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
            if let Some(chat_id) = chat_id {
                if let Some(mode) = args.output_mode {
                    realtime
                        .call(proto::SetAgentParticipationInput {
                            peer_id: Some(chat_peer(chat_id)),
                            bot_user_id,
                            output_mode: Some(mode.protocol_value() as i32),
                            ..Default::default()
                        })
                        .await?;
                }
                let thread_mode =
                    read_thread_output_mode(&mut realtime, bot_user_id, chat_id).await?;
                let default_mode = read_agent_settings(&mut realtime, bot_user_id)
                    .await?
                    .map(|settings| settings.default_output_mode)
                    .unwrap_or_default();
                if json {
                    output::print_json(
                        &ThreadOutputModeOutput {
                            bot_user_id,
                            chat_id,
                            output_mode: thread_mode.map(output_mode_label),
                            default_output_mode: output_mode_label(default_mode),
                        },
                        json_format,
                    )?;
                } else {
                    match thread_mode {
                        Some(mode) => {
                            println!("Output mode in chat {chat_id}: {}", output_mode_label(mode))
                        }
                        None => println!(
                            "Output mode in chat {chat_id}: bot default ({})",
                            output_mode_label(default_mode)
                        ),
                    }
                }
                return Ok(());
            }
            let settings = match args.output_mode {
                None => {
                    let settings = read_agent_settings(&mut realtime, bot_user_id).await?;
                    if json {
                        return Ok(output::print_json(
                            &proto::GetAgentSettingsResult { settings },
                            json_format,
                        )?);
                    }
                    settings
                }
                Some(mode) => {
                    let payload = match realtime
                        .call(proto::UpdateAgentSettingsInput {
                            bot_user_id,
                            default_output_mode: Some(mode.protocol_value() as i32),
                            open_to_everyone: None,
                        })
                        .await
                    {
                        Ok(payload) => payload,
                        Err(error) => {
                            // Older servers keep the default on the agent runtime only.
                            let runtime = realtime
                                .call(proto::GetAgentRuntimeInput { bot_user_id })
                                .await
                                .ok()
                                .and_then(|payload| payload.runtime);
                            if runtime.is_none() {
                                return Err(CliError::invalid_args(format!(
                                    "Bot {bot_user_id} hasn't connected an agent yet. Output mode applies to agent bots; set one up with `inline agents`, then try again."
                                ))
                                .into());
                            }
                            return Err(error);
                        }
                    };
                    if json {
                        return Ok(output::print_json(&payload, json_format)?);
                    }
                    // Servers before the settings read return only the runtime.
                    payload.settings.or_else(|| {
                        payload.runtime.map(|runtime| proto::AgentSettings {
                            bot_user_id,
                            default_output_mode: runtime.default_output_mode,
                            ..Default::default()
                        })
                    })
                }
            };
            let mode = settings
                .as_ref()
                .map(|settings| settings.default_output_mode)
                .unwrap_or_default();
            println!("Output mode: {}", output_mode_label(mode));
        }
        BotsCommand::Access { command } => match command {
            BotsAccessCommand::List(args) => {
                let Some(bot_user_id) = args.selection.single() else {
                    let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                    return Box::pin(print_bot_overview(
                        &mut realtime,
                        &args.selection,
                        json,
                        json_format,
                    ))
                    .await;
                };
                let bot_user_id = validate_positive_id_arg("--bot-user-id", bot_user_id)?;
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::ListAgentGrantsInput {
                        bot_user_id,
                        include_all_subjects: Some(true),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    // Servers before this setting report every bot as not open.
                    let open = read_agent_settings(&mut realtime, bot_user_id)
                        .await
                        .ok()
                        .flatten()
                        .is_some_and(|settings| settings.open_to_everyone);
                    if open {
                        println!("Anyone on Inline can message this bot.");
                    }
                    print_grants(&payload.grants, open);
                }
            }
            BotsAccessCommand::Open(args) => {
                Box::pin(open_or_close(
                    config,
                    auth_store,
                    args,
                    true,
                    json,
                    json_format,
                ))
                .await?;
            }
            BotsAccessCommand::Close(args) => {
                Box::pin(open_or_close(
                    config,
                    auth_store,
                    args,
                    false,
                    json,
                    json_format,
                ))
                .await?;
            }
            BotsAccessCommand::Grant(args) if args.selection.single().is_none() || args.dry_run => {
                let subject = access_subject(&args.subject)?;
                let operations = grant_args_operations(&args);
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let bots =
                    Box::pin(resolve_bulk_targets(&mut realtime, &args.selection, json)).await?;
                let results = Box::pin(bulk_grant(
                    &mut realtime,
                    &bots,
                    &subject,
                    Some(&operations),
                    args.dry_run,
                ))
                .await;
                finish_bulk(
                    "grant",
                    format!("Grant {} access", subject_label(Some(&subject), 0)),
                    args.dry_run,
                    results,
                    json,
                    json_format,
                )?;
            }
            BotsAccessCommand::Revoke(args)
                if args.selection.single().is_none() || args.dry_run =>
            {
                let subject = access_subject(&args.subject)?;
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let bots =
                    Box::pin(resolve_bulk_targets(&mut realtime, &args.selection, json)).await?;
                let results = Box::pin(bulk_grant(
                    &mut realtime,
                    &bots,
                    &subject,
                    None,
                    args.dry_run,
                ))
                .await;
                finish_bulk(
                    "revoke",
                    format!("Revoke {}'s access", subject_label(Some(&subject), 0)),
                    args.dry_run,
                    results,
                    json,
                    json_format,
                )?;
            }
            BotsAccessCommand::Grant(args) => {
                let bot_user_id = args.selection.require_single("Granting access")?;
                let subject = access_subject(&args.subject)?;
                let label = subject_label(Some(&subject), 0);
                let operations = grant_args_operations(&args);
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::SetAgentGrantInput {
                        bot_user_id,
                        user_id: args.subject.user_id.unwrap_or_default(),
                        operations,
                        subject: Some(subject),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    let operations = payload
                        .grant
                        .as_ref()
                        .map(|grant| operations_label(&grant.operations))
                        .unwrap_or_else(|| "-".to_string());
                    println!("Granted {label} access to bot {bot_user_id}: {operations}.");
                }
            }
            BotsAccessCommand::Revoke(args) => {
                let bot_user_id = args.selection.require_single("Revoking access")?;
                let subject = access_subject(&args.subject)?;
                let label = subject_label(Some(&subject), 0);
                let mut realtime = connect_authenticated_realtime(config, auth_store).await?;
                let payload = realtime
                    .call(proto::DeleteAgentGrantInput {
                        bot_user_id,
                        user_id: args.subject.user_id.unwrap_or_default(),
                        subject: Some(subject),
                    })
                    .await?;
                if json {
                    output::print_json(&payload, json_format)?;
                } else {
                    println!("Revoked {label}'s access to bot {bot_user_id}.");
                }
            }
        },
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grant_operations_default_to_invoke_and_steer() {
        assert_eq!(
            grant_operations(&[]),
            vec![
                proto::AgentGrantOperation::Invoke as i32,
                proto::AgentGrantOperation::Steer as i32
            ]
        );
    }

    #[test]
    fn grant_operations_dedupe_in_order() {
        assert_eq!(
            grant_operations(&[
                BotGrantOperation::Approve,
                BotGrantOperation::Invoke,
                BotGrantOperation::Approve,
            ]),
            vec![
                proto::AgentGrantOperation::Approve as i32,
                proto::AgentGrantOperation::Invoke as i32
            ]
        );
    }

    fn grant(subject: Option<proto::access_subject::Subject>, user_id: i64) -> proto::AgentGrant {
        proto::AgentGrant {
            user_id,
            subject: subject.map(|subject| proto::AccessSubject {
                subject: Some(subject),
            }),
            ..Default::default()
        }
    }

    #[test]
    fn shared_with_matches_the_apps() {
        use proto::access_subject::Subject;
        assert_eq!(shared_with_summary(&[], false), "only you");
        assert_eq!(
            shared_with_summary(&[grant(Some(Subject::UserId(7)), 7)], true),
            "everyone"
        );
        assert_eq!(
            shared_with_summary(
                &[
                    grant(Some(Subject::UserId(7)), 7),
                    grant(None, 8),
                    grant(Some(Subject::SpaceId(3)), 0),
                    grant(Some(Subject::GroupId(4)), 0),
                ],
                false
            ),
            "1 space, 1 group, 2 people"
        );
        assert_eq!(
            shared_with_summary(&[grant(Some(Subject::UserId(7)), 7)], false),
            "1 person"
        );
    }

    #[test]
    fn grants_match_by_subject_or_legacy_user_id() {
        use proto::access_subject::Subject;
        let person = proto::AccessSubject {
            subject: Some(Subject::UserId(7)),
        };
        let space = proto::AccessSubject {
            subject: Some(Subject::SpaceId(7)),
        };
        assert!(grant_matches(&grant(Some(Subject::UserId(7)), 7), &person));
        assert!(grant_matches(&grant(None, 7), &person));
        assert!(!grant_matches(&grant(None, 7), &space));
        assert!(!grant_matches(
            &grant(Some(Subject::SpaceId(7)), 0),
            &person
        ));
        assert!(grant_matches(&grant(Some(Subject::SpaceId(7)), 0), &space));
    }

    #[test]
    fn bulk_results_skip_bots_already_set() {
        let bot = TargetBot { id: 9, user: None };
        let same = BulkResult::compared(&bot, "friendly".into(), "friendly".into(), false);
        assert_eq!(same.status, BulkStatus::Unchanged);
        let change = BulkResult::compared(&bot, "unset".into(), "friendly".into(), false);
        assert_eq!(change.status, BulkStatus::Changed);
        let preview = BulkResult::compared(&bot, "unset".into(), "friendly".into(), true);
        assert_eq!(preview.status, BulkStatus::WouldChange);
        assert_eq!(bot.label(), "bot 9");
        assert_eq!(
            sorted_operations(&[3, 1, 3, 2]),
            vec![1, 2, 3],
            "grant comparisons ignore order and repeats"
        );
    }

    #[test]
    fn selection_keeps_the_single_bot_form() {
        let one = BotSelectionArgs {
            bot_user_ids: vec![9],
            ..Default::default()
        };
        assert_eq!(one.single(), Some(9));
        assert!(!one.is_empty());
        let many = BotSelectionArgs {
            bot_user_ids: vec![9, 10],
            ..Default::default()
        };
        assert_eq!(many.single(), None);
        assert!(many.require_single("--chat-id").is_err());
        let none = BotSelectionArgs::default();
        assert!(none.is_empty());
        assert!(none.require_some().is_err());
        let all = BotSelectionArgs {
            all: true,
            ..Default::default()
        };
        assert!(all.single().is_none() && all.require_some().is_ok());
    }

    #[test]
    fn labels_preserve_an_unset_output_preference() {
        assert_eq!(output_mode_label(0), "unset");
        assert_eq!(
            output_mode_label(BotOutputMode::Detailed.protocol_value() as i32),
            "detailed"
        );
        assert_eq!(
            BotOutputMode::Default.protocol_value(),
            proto::AgentOutputMode::Unspecified
        );
        assert_eq!(
            output_mode_label(proto::AgentOutputMode::Friendly as i32),
            "friendly"
        );
        assert_eq!(
            operations_label(&[
                proto::AgentGrantOperation::Invoke as i32,
                proto::AgentGrantOperation::Configure as i32
            ]),
            "admin (invoke, configure)"
        );
        assert_eq!(
            operations_label(&[proto::AgentGrantOperation::Invoke as i32]),
            "invoke"
        );
        assert_eq!(operations_label(&[]), "-");
    }
}
