//! Bot chat settings for v2 works: Agent Settings and the composer chain
//! (spec §6, decided Oct 26). Model, reasoning and permission mode come from
//! the harness's own catalog and apply to this thread's work from the next
//! message on. The folder is a choice among the agent's folders until a
//! session works there. Item IDs match what the apps already read
//! (`ComposeAgentSettingsItem`).

use inline_agent_bridge::DriverUsageWindow;
use inline_agent_bridge::harness::{Catalog, SettingsChange};
use inline_client::{
    AgentConfigurationCatalog, AgentModelCatalog, AgentModelOption, AgentProjectCatalog,
    AgentReasoningCatalog, AgentReasoningEffortOption, BotCapability, BotCapabilityKind,
    BotChatSettingsControl, BotChatSettingsDocument, BotChatSettingsInfoTone, BotChatSettingsItem,
    BotChatSettingsProblem, BotChatSettingsProblemCode, BotChatSettingsResponse,
    BotChatSettingsSection, BotChatSettingsSelectOption, BotSettingsValue,
};

pub(crate) const SETTINGS_VERSION: u32 = 1;
const AGENT_CONFIGURATION_VERSION: u32 = 1;

pub(crate) const ITEM_MODEL: &str = "agent.model";
pub(crate) const ITEM_REASONING: &str = "agent.reasoning";
pub(crate) const ITEM_PERMISSIONS: &str = "agent.permissions";
pub(crate) const ITEM_COMPACT: &str = "session.compact";
const ITEM_FOLDER: &str = "workspace.folder";
/// The thread's folder as a choice; the apps read this id's select.
pub(crate) const ITEM_FOLDER_CHOICE: &str = "workspace.project";
/// Account limits. Each window item's ID carries its numbers for Compose's
/// usage popover, and its position to stay unique:
/// `account.usage.window:<minutes>:<used %>:<resets at>:<index>`.
const SECTION_USAGE: &str = "account.usage";
const ITEM_USAGE_WINDOW: &str = "account.usage.window";
/// This thread's context window: `session.context:<used tokens>:<window>`.
const ITEM_CONTEXT: &str = "session.context";
/// "Use the harness's default", as a select value.
const DEFAULT_VALUE: &str = "__inline_provider_default__";
/// The thread's folder when it is not among the choices.
const CURRENT_FOLDER_VALUE: &str = "__inline_current_folder__";
/// Inline takes at most 100 options per select; one stays free for the
/// thread's folder when it is not among the choices.
const MAX_FOLDER_OPTIONS: usize = 99;

/// What a settings invocation asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Invocation {
    Change(SettingsChange),
    /// The thread's folder, by its choice id.
    Folder(String),
    Compact,
}

/// The capabilities that make the apps offer settings and the chain.
pub(crate) fn capabilities(
    catalog: &Catalog,
    folders: Option<AgentProjectCatalog>,
) -> Vec<BotCapability> {
    vec![
        BotCapability {
            kind: BotCapabilityKind::ChatSettings,
            version: SETTINGS_VERSION,
            agent_configuration: None,
        },
        BotCapability {
            kind: BotCapabilityKind::AgentConfiguration,
            version: AGENT_CONFIGURATION_VERSION,
            agent_configuration: Some(configuration_catalog(catalog, folders)),
        },
    ]
}

/// Folders, models and efforts as the apps' Agent configuration catalog
/// (folders are its `projects`).
pub(crate) fn configuration_catalog(
    catalog: &Catalog,
    folders: Option<AgentProjectCatalog>,
) -> AgentConfigurationCatalog {
    let mut efforts: Vec<AgentReasoningEffortOption> = Vec::new();
    for model in &catalog.models {
        for effort in &model.reasoning {
            if !efforts.iter().any(|known| known.id == effort.value) {
                efforts.push(AgentReasoningEffortOption {
                    id: effort.value.clone(),
                    label: effort.label.clone(),
                    description: effort.description.clone(),
                });
            }
        }
    }
    AgentConfigurationCatalog {
        projects: folders,
        models: (!catalog.models.is_empty()).then(|| AgentModelCatalog {
            options: catalog
                .models
                .iter()
                .map(|model| AgentModelOption {
                    id: model.value.clone(),
                    label: model.label.clone(),
                    description: model.description.clone(),
                    reasoning_effort_ids: model
                        .reasoning
                        .iter()
                        .map(|effort| effort.value.clone())
                        .collect(),
                    default_reasoning_effort_id: model.default_reasoning.clone(),
                })
                .collect(),
            default_model_id: catalog
                .models
                .iter()
                .find(|model| model.is_default)
                .map(|model| model.value.clone()),
        }),
        reasoning: (!efforts.is_empty()).then_some(AgentReasoningCatalog { options: efforts }),
    }
}

/// A folder a thread can pick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Folder {
    pub id: String,
    pub label: String,
    pub description: Option<String>,
}

/// Where the document's facts come from.
pub(crate) struct DocumentFacts<'a> {
    pub catalog: &'a Catalog,
    /// This thread's choices; `None` fields are the harness's defaults.
    pub settings: &'a SettingsChange,
    pub folder_label: &'a str,
    pub machine_label: &'a str,
    /// The folders this thread can pick here; empty shows its folder only.
    pub folders: &'a [Folder],
    /// The thread's folder among `folders`.
    pub folder_id: Option<&'a str>,
    /// A session works in the folder, so it stays.
    pub folder_fixed: bool,
    /// A session is open, so it can be compacted now.
    pub can_compact: bool,
    /// The structured compact operation is supported (or not yet known for
    /// native harnesses). A provider's `/compact` command is a separate route.
    pub compact_supported: bool,
    /// The account's usage windows, as the harness last reported them.
    pub usage: &'a [DriverUsageWindow],
    /// This thread's context fill, once a turn reported it.
    pub context: Option<ContextUsage>,
}

/// How full a thread's context window is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ContextUsage {
    pub used: u64,
    pub window: u64,
}

pub(crate) fn document(facts: &DocumentFacts<'_>) -> BotChatSettingsDocument {
    let catalog = facts.catalog;
    let settings = facts.settings;
    let mut agent = Vec::new();
    if !catalog.models.is_empty() {
        agent.push(select(
            ITEM_MODEL,
            "Model",
            settings.model.as_deref(),
            catalog.models.iter().map(|model| {
                (
                    model.value.clone(),
                    model.label.clone(),
                    model.description.clone(),
                )
            }),
        ));
    }
    let model = settings
        .model
        .as_deref()
        .and_then(|id| catalog.models.iter().find(|model| model.value == id))
        .or_else(|| catalog.models.iter().find(|model| model.is_default));
    if let Some(model) = model.filter(|model| !model.reasoning.is_empty()) {
        agent.push(select(
            ITEM_REASONING,
            "Reasoning",
            settings.effort.as_deref(),
            model.reasoning.iter().map(|effort| {
                (
                    effort.value.clone(),
                    effort.label.clone(),
                    effort.description.clone(),
                )
            }),
        ));
    }
    if !catalog.permission_modes.is_empty() {
        agent.push(select(
            ITEM_PERMISSIONS,
            "Permissions",
            settings.permission_mode.as_deref(),
            catalog.permission_modes.iter().map(|mode| {
                (
                    mode.value.clone(),
                    mode.label.clone(),
                    mode.description.clone(),
                )
            }),
        ));
    }
    let mut session: Vec<BotChatSettingsItem> = facts
        .context
        .filter(|context| context.window > 0)
        .map(context_item)
        .into_iter()
        .collect();
    if facts.compact_supported {
        session.push(BotChatSettingsItem {
            id: ITEM_COMPACT.to_owned(),
            label: Some("Compact context".to_owned()),
            description: Some("Summarize this thread's session to free context.".to_owned()),
            disabled: !facts.can_compact,
            disabled_reason: (!facts.can_compact)
                .then(|| "Nothing is open in this thread yet.".to_owned()),
            control: BotChatSettingsControl::Button,
        });
    }
    let workspace = if facts.folders.is_empty() {
        vec![BotChatSettingsItem {
            id: ITEM_FOLDER.to_owned(),
            label: Some("Folder".to_owned()),
            description: Some(format!("On {}", facts.machine_label)),
            disabled: false,
            disabled_reason: None,
            control: BotChatSettingsControl::Info {
                text: facts.folder_label.to_owned(),
                tone: BotChatSettingsInfoTone::Neutral,
            },
        }]
    } else {
        vec![folder_choice(facts)]
    };
    let usage = usage_items(facts.usage);
    let sections = [
        (SECTION_USAGE, "Usage", usage),
        ("agent", "Agent", agent),
        ("session", "Session", session),
        ("workspace", "Workspace", workspace),
    ]
    .into_iter()
    .filter(|(_, _, items)| !items.is_empty())
    .map(|(id, title, items)| BotChatSettingsSection {
        id: id.to_owned(),
        title: Some(title.to_owned()),
        description: None,
        items,
    })
    .collect();
    BotChatSettingsDocument {
        version: SETTINGS_VERSION,
        revision: revision(facts),
        sections,
    }
}

/// One read-only item per usage window, 5-hour first, in the harness's
/// numbers. They stay out of the revision: usage is not a choice.
fn usage_items(windows: &[DriverUsageWindow]) -> Vec<BotChatSettingsItem> {
    let mut windows: Vec<&DriverUsageWindow> = windows.iter().take(8).collect();
    windows.sort_by_key(|window| window.window_minutes.unwrap_or(i64::MAX));
    windows
        .iter()
        .enumerate()
        .map(|(index, window)| {
            let shared = windows
                .iter()
                .filter(|other| other.window_minutes == window.window_minutes)
                .count()
                > 1;
            BotChatSettingsItem {
                id: format!(
                    "{ITEM_USAGE_WINDOW}:{}:{}:{}:{index}",
                    window.window_minutes.unwrap_or(0),
                    window.used_percent,
                    window.resets_at.unwrap_or(0)
                ),
                label: Some(window_title(window, shared)),
                description: window
                    .resets_at
                    .and_then(|seconds| chrono::DateTime::from_timestamp(seconds, 0))
                    .map(|time| format!("Resets {}", time.format("%b %-d at %H:%M UTC"))),
                disabled: true,
                disabled_reason: None,
                control: BotChatSettingsControl::Info {
                    text: format!("{}% used", window.used_percent),
                    tone: if window.used_percent >= 100 {
                        BotChatSettingsInfoTone::Warning
                    } else {
                        BotChatSettingsInfoTone::Neutral
                    },
                },
            }
        })
        .collect()
}

/// "5-hour limit", "Weekly · all models"; the harness's own name tells
/// windows of the same length apart (Claude's `seven_day_opus`).
fn window_title(window: &DriverUsageWindow, shared: bool) -> String {
    let base = match window.window_minutes {
        Some(10_080) if window.label.starts_with("seven_day") => "Weekly".to_owned(),
        Some(10_080) => "Weekly limit".to_owned(),
        Some(minutes) if minutes % 60 == 0 => format!("{}-hour limit", minutes / 60),
        Some(minutes) => format!("{minutes}-minute limit"),
        None => window.label.clone(),
    };
    let scope = window
        .label
        .strip_prefix("seven_day_")
        .or_else(|| window.label.strip_prefix("five_hour_"))
        .map(|model| {
            let mut name = model.replace('_', " ");
            if let Some(first) = name.get_mut(..1) {
                first.make_ascii_uppercase();
            }
            name
        });
    match scope {
        Some(scope) => format!("{base} · {scope}"),
        None if window.label == "seven_day" => format!("{base} · all models"),
        None if shared && window.window_minutes.is_some() => format!("{base} · {}", window.label),
        None => base,
    }
}

fn context_item(context: ContextUsage) -> BotChatSettingsItem {
    let used = context.used.min(context.window);
    let percent = used.saturating_mul(100) / context.window;
    BotChatSettingsItem {
        id: format!("{ITEM_CONTEXT}:{}:{}", context.used, context.window),
        label: Some("Context window".to_owned()),
        description: Some(format!(
            "{} of {} tokens used",
            token_count(context.used),
            token_count(context.window)
        )),
        disabled: true,
        disabled_reason: None,
        control: BotChatSettingsControl::Info {
            text: format!("{percent}% full"),
            tone: if percent >= 90 {
                BotChatSettingsInfoTone::Warning
            } else {
                BotChatSettingsInfoTone::Neutral
            },
        },
    }
}

/// "850", "439k", "1.2M".
fn token_count(tokens: u64) -> String {
    match tokens {
        0..1_000 => tokens.to_string(),
        1_000..1_000_000 => format!("{}k", tokens / 1_000),
        _ => {
            let tenths = tokens / 100_000;
            if tenths.is_multiple_of(10) {
                format!("{}M", tenths / 10)
            } else {
                format!("{}.{}M", tenths / 10, tenths % 10)
            }
        }
    }
}

/// The thread's folder as a choice. Once a session works in it, it stays:
/// the choice is shown, disabled, with how to work elsewhere.
fn folder_choice(facts: &DocumentFacts<'_>) -> BotChatSettingsItem {
    let fixed = facts.folder_fixed;
    let mut options: Vec<BotChatSettingsSelectOption> = facts
        .folders
        .iter()
        .map(|folder| BotChatSettingsSelectOption {
            value: folder.id.clone(),
            label: folder.label.clone(),
            description: folder.description.clone(),
            disabled: fixed,
        })
        .collect();
    if options.len() > MAX_FOLDER_OPTIONS {
        // Keep the thread's own choice when it falls past the cut.
        let chosen = facts
            .folder_id
            .and_then(|id| options.iter().position(|option| option.value == id))
            .filter(|index| *index >= MAX_FOLDER_OPTIONS)
            .map(|index| options.remove(index));
        options.truncate(MAX_FOLDER_OPTIONS - usize::from(chosen.is_some()));
        options.extend(chosen);
    }
    let value = match facts.folder_id {
        Some(id) if options.iter().any(|option| option.value == id) => id.to_owned(),
        _ => {
            options.insert(
                0,
                BotChatSettingsSelectOption {
                    value: CURRENT_FOLDER_VALUE.to_owned(),
                    label: facts.folder_label.to_owned(),
                    description: Some("Not among this agent's folders.".to_owned()),
                    disabled: true,
                },
            );
            CURRENT_FOLDER_VALUE.to_owned()
        }
    };
    BotChatSettingsItem {
        id: ITEM_FOLDER_CHOICE.to_owned(),
        label: Some("Folder".to_owned()),
        description: Some(format!("On {}", facts.machine_label)),
        disabled: fixed,
        disabled_reason: fixed.then(|| folder_fixed(facts.folder_label)),
        control: BotChatSettingsControl::Select { value, options },
    }
}

/// Why a thread's folder can't change: a session works there.
pub(crate) fn folder_fixed(folder_label: &str) -> String {
    format!(
        "This thread's session works in {folder_label}. Start a new thread to work in another folder."
    )
}

/// Changes with every value the document shows, so a stale invocation is
/// refused rather than applied to settings the person did not see.
fn revision(facts: &DocumentFacts<'_>) -> String {
    let settings = facts.settings;
    let models: Vec<&str> = facts
        .catalog
        .models
        .iter()
        .map(|model| model.value.as_str())
        .collect();
    let key = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}",
        settings.model.as_deref().unwrap_or(""),
        settings.effort.as_deref().unwrap_or(""),
        settings.permission_mode.as_deref().unwrap_or(""),
        models.join(","),
        facts.can_compact,
        facts.compact_supported,
        facts.folder_label,
        facts.folder_id.unwrap_or(""),
        facts.folder_fixed,
    );
    let digest = <sha2::Sha256 as sha2::Digest>::digest(key.as_bytes());
    digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn select(
    id: &str,
    label: &str,
    current: Option<&str>,
    options: impl Iterator<Item = (String, String, Option<String>)>,
) -> BotChatSettingsItem {
    let mut choices = vec![BotChatSettingsSelectOption {
        value: DEFAULT_VALUE.to_owned(),
        label: "Default".to_owned(),
        description: Some("What the harness uses on its own.".to_owned()),
        disabled: false,
    }];
    choices.extend(
        options.map(|(value, label, description)| BotChatSettingsSelectOption {
            value,
            label,
            description,
            disabled: false,
        }),
    );
    BotChatSettingsItem {
        id: id.to_owned(),
        label: Some(label.to_owned()),
        description: None,
        disabled: false,
        disabled_reason: None,
        control: BotChatSettingsControl::Select {
            value: current.unwrap_or(DEFAULT_VALUE).to_owned(),
            options: choices,
        },
    }
}

/// Reads one invocation against the catalog. A value outside the catalog is
/// refused, never passed through.
pub(crate) fn invocation(
    item_id: &str,
    value: Option<&BotSettingsValue>,
    catalog: &Catalog,
) -> Result<Invocation, &'static str> {
    if item_id == ITEM_COMPACT {
        return Ok(Invocation::Compact);
    }
    let value = match value {
        Some(BotSettingsValue::String(value)) => value.as_str(),
        _ => return Err("Choose a value."),
    };
    if item_id == ITEM_FOLDER_CHOICE {
        if value == CURRENT_FOLDER_VALUE {
            return Err("Choose one of the agent's folders.");
        }
        return Ok(Invocation::Folder(value.to_owned()));
    }
    let chosen = (value != DEFAULT_VALUE).then(|| value.to_owned());
    let mut change = SettingsChange::default();
    match item_id {
        ITEM_MODEL => {
            if let Some(model) = &chosen
                && !catalog.models.iter().any(|known| &known.value == model)
            {
                return Err("That model is not available on this machine.");
            }
            change.model = Some(chosen.unwrap_or_default());
        }
        ITEM_REASONING => {
            if let Some(effort) = &chosen
                && !catalog
                    .models
                    .iter()
                    .any(|model| model.reasoning.iter().any(|known| &known.value == effort))
            {
                return Err("That reasoning level is not available.");
            }
            change.effort = Some(chosen.unwrap_or_default());
        }
        ITEM_PERMISSIONS => {
            if let Some(mode) = &chosen
                && !catalog
                    .permission_modes
                    .iter()
                    .any(|known| &known.value == mode)
            {
                return Err("That permission mode is not available.");
            }
            change.permission_mode = Some(chosen.unwrap_or_default());
        }
        _ => return Err("This setting is not available for this agent."),
    }
    Ok(Invocation::Change(change))
}

/// A bound thread's composer chain as a change: a model or reasoning this
/// machine no longer offers falls back to the default instead of failing
/// the turn.
pub(crate) fn bound(
    model: Option<String>,
    effort: Option<String>,
    catalog: &Catalog,
) -> SettingsChange {
    let model = model.filter(|model| catalog.models.iter().any(|known| &known.value == model));
    let effort = effort.filter(|effort| {
        catalog
            .models
            .iter()
            .any(|model| model.reasoning.iter().any(|known| &known.value == effort))
    });
    SettingsChange {
        model: Some(model.unwrap_or_default()),
        effort: Some(effort.unwrap_or_default()),
        ..SettingsChange::default()
    }
}

/// Folds a change into a thread's choices. An empty string clears a field
/// back to the harness's default.
pub(crate) fn merge(into: &mut SettingsChange, change: &SettingsChange) {
    let apply = |field: &mut Option<String>, value: &Option<String>| {
        if let Some(value) = value {
            *field = (!value.is_empty()).then(|| value.clone());
        }
    };
    apply(&mut into.model, &change.model);
    apply(&mut into.effort, &change.effort);
    apply(&mut into.speed, &change.speed);
    apply(&mut into.permission_mode, &change.permission_mode);
    if change.folder.is_some() {
        into.folder = change.folder.clone();
    }
}

/// The change as the harness takes it: cleared fields are left out, since
/// the harness has no "back to default" for a running session. The folder is
/// where a session opens, never a change to one that is open.
pub(crate) fn effective(change: &SettingsChange) -> SettingsChange {
    let keep = |value: &Option<String>| value.clone().filter(|value| !value.is_empty());
    SettingsChange {
        model: keep(&change.model),
        effort: keep(&change.effort),
        speed: keep(&change.speed),
        permission_mode: keep(&change.permission_mode),
        folder: None,
    }
}

/// A command's argument as a select value: "default" clears.
pub(crate) fn command_value(argument: &str) -> &str {
    if argument.eq_ignore_ascii_case("default") {
        DEFAULT_VALUE
    } else {
        argument
    }
}

/// `/model`, `/reasoning` or `/permissions` with no argument: the current
/// value and the choices.
pub(crate) fn describe(item: &str, catalog: &Catalog, settings: &SettingsChange) -> String {
    let (label, current, choices): (&str, &Option<String>, Vec<String>) = match item {
        ITEM_MODEL => (
            "Model",
            &settings.model,
            catalog
                .models
                .iter()
                .map(|model| model.value.clone())
                .collect(),
        ),
        ITEM_REASONING => ("Reasoning", &settings.effort, {
            let model = settings
                .model
                .as_deref()
                .and_then(|id| catalog.models.iter().find(|model| model.value == id))
                .or_else(|| catalog.models.iter().find(|model| model.is_default));
            model.map_or_else(Vec::new, |model| {
                model
                    .reasoning
                    .iter()
                    .map(|effort| effort.value.clone())
                    .collect()
            })
        }),
        _ => (
            "Permissions",
            &settings.permission_mode,
            catalog
                .permission_modes
                .iter()
                .map(|mode| mode.value.clone())
                .collect(),
        ),
    };
    let command = match item {
        ITEM_MODEL => "/model",
        ITEM_REASONING => "/reasoning",
        _ => "/permissions",
    };
    let current = current.as_deref().unwrap_or("default");
    if choices.is_empty() {
        return format!("{label}: {current}. This harness offers no choices here.");
    }
    format!(
        "{label}: {current}. Choose with {command} <value>: default, {}.",
        choices.join(", ")
    )
}

pub(crate) fn problem(
    code: BotChatSettingsProblemCode,
    message: &str,
    current: Option<BotChatSettingsDocument>,
) -> BotChatSettingsResponse {
    BotChatSettingsResponse::Problem(BotChatSettingsProblem {
        code,
        message: message.to_owned(),
        current_document: current,
    })
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use inline_agent_bridge::{DriverModelOption, DriverSettingOption};

    use super::*;

    fn option(value: &str) -> DriverSettingOption {
        DriverSettingOption {
            value: value.to_owned(),
            label: value.to_uppercase(),
            description: None,
            disabled: false,
        }
    }

    fn catalog() -> Catalog {
        Catalog {
            models: vec![
                DriverModelOption {
                    value: "sol".to_owned(),
                    label: "Sol".to_owned(),
                    description: None,
                    reasoning: vec![option("low"), option("high")],
                    default_reasoning: Some("low".to_owned()),
                    is_default: true,
                },
                DriverModelOption {
                    value: "luna".to_owned(),
                    label: "Luna".to_owned(),
                    description: None,
                    reasoning: Vec::new(),
                    default_reasoning: None,
                    is_default: false,
                },
            ],
            permission_modes: vec![option("default"), option("bypassPermissions")],
            ..Catalog::default()
        }
    }

    #[test]
    fn unsupported_compaction_is_not_offered_even_with_an_open_session() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let mut facts = facts(&catalog, &settings);
        facts.compact_supported = false;
        let document = document(&facts);
        assert!(
            !document
                .sections
                .iter()
                .flat_map(|section| &section.items)
                .any(|item| item.id == ITEM_COMPACT)
        );
    }

    fn facts<'a>(catalog: &'a Catalog, settings: &'a SettingsChange) -> DocumentFacts<'a> {
        DocumentFacts {
            catalog,
            settings,
            folder_label: "project",
            machine_label: "MacBook",
            folders: &[],
            folder_id: None,
            folder_fixed: false,
            can_compact: true,
            compact_supported: true,
            usage: &[],
            context: None,
        }
    }

    fn folders() -> Vec<Folder> {
        ["inline", "secret-sauce"]
            .into_iter()
            .map(|name| Folder {
                id: format!("workspace-{name}"),
                label: name.to_owned(),
                description: None,
            })
            .collect()
    }

    #[test]
    fn a_long_folder_list_fits_the_select_and_keeps_the_threads_choice() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let folders: Vec<Folder> = (0..150)
            .map(|index| Folder {
                id: format!("workspace-{index}"),
                label: format!("folder {index}"),
                description: None,
            })
            .collect();
        let document = document(&DocumentFacts {
            folders: &folders,
            folder_id: Some("workspace-140"),
            ..facts(&catalog, &settings)
        });
        let BotChatSettingsControl::Select { value, options } =
            &item(&document, ITEM_FOLDER_CHOICE).control
        else {
            panic!("a folder select");
        };
        assert!(options.len() <= 100, "{}", options.len());
        assert_eq!(value, "workspace-140");
        assert!(options.iter().any(|option| option.value == "workspace-140"));
    }

    #[test]
    fn usage_windows_with_equal_readings_keep_unique_ids() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let window = |label: &str| DriverUsageWindow {
            label: label.to_owned(),
            used_percent: 18,
            window_minutes: Some(10_080),
            resets_at: Some(1_793_000_000),
        };
        let windows = [window("seven_day"), window("seven_day_sonnet")];
        let document = document(&DocumentFacts {
            usage: &windows,
            ..facts(&catalog, &settings)
        });
        let ids: Vec<&str> = document
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .map(|item| item.id.as_str())
            .collect();
        let unique: std::collections::HashSet<&str> = ids.iter().copied().collect();
        assert_eq!(
            unique.len(),
            ids.len(),
            "Inline refuses duplicate ids: {ids:?}"
        );
    }

    #[test]
    fn usage_windows_and_context_read_as_items_compose_can_parse() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let windows = [
            DriverUsageWindow {
                label: "seven_day".to_owned(),
                used_percent: 18,
                window_minutes: Some(10_080),
                resets_at: Some(1_793_000_000),
            },
            DriverUsageWindow {
                label: "five_hour".to_owned(),
                used_percent: 26,
                window_minutes: Some(300),
                resets_at: None,
            },
        ];
        let document = document(&DocumentFacts {
            usage: &windows,
            context: Some(ContextUsage {
                used: 439_000,
                window: 475_000,
            }),
            ..facts(&catalog, &settings)
        });
        let usage = &document.sections[0];
        assert_eq!(usage.id, "account.usage");
        let titles: Vec<(&str, Option<&str>)> = usage
            .items
            .iter()
            .map(|item| (item.id.as_str(), item.label.as_deref()))
            .collect();
        assert_eq!(
            titles,
            vec![
                ("account.usage.window:300:26:0:0", Some("5-hour limit")),
                (
                    "account.usage.window:10080:18:1793000000:1",
                    Some("Weekly · all models")
                ),
            ]
        );
        let context = item(&document, "session.context:439000:475000");
        assert!(matches!(
            &context.control,
            BotChatSettingsControl::Info { text, .. } if text == "92% full"
        ));
        assert_eq!(
            context.description.as_deref(),
            Some("439k of 475k tokens used")
        );
        assert_eq!(
            document.revision,
            super::document(&facts(&catalog, &settings)).revision,
            "usage is not part of the revision"
        );
    }

    fn item<'a>(document: &'a BotChatSettingsDocument, id: &str) -> &'a BotChatSettingsItem {
        document
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .find(|item| item.id == id)
            .expect(id)
    }

    #[test]
    fn the_document_offers_the_harness_catalog_with_a_default() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let document = document(&facts(&catalog, &settings));
        let BotChatSettingsControl::Select { value, options } =
            &item(&document, ITEM_MODEL).control
        else {
            panic!("model select");
        };
        assert_eq!(value, DEFAULT_VALUE);
        let values: Vec<&str> = options.iter().map(|option| option.value.as_str()).collect();
        assert_eq!(values, [DEFAULT_VALUE, "sol", "luna"]);
        // Reasoning follows the default model's efforts.
        let BotChatSettingsControl::Select { options, .. } =
            &item(&document, ITEM_REASONING).control
        else {
            panic!("reasoning select");
        };
        assert_eq!(options.len(), 3);
        assert!(matches!(
            item(&document, ITEM_FOLDER).control,
            BotChatSettingsControl::Info { .. }
        ));
    }

    #[test]
    fn the_folder_is_a_choice_until_a_session_works_there() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let folders = folders();
        let open = DocumentFacts {
            folder_label: "inline",
            folders: &folders,
            folder_id: Some("workspace-inline"),
            ..facts(&catalog, &settings)
        };
        let offered = document(&open);
        assert!(
            offered
                .sections
                .iter()
                .flat_map(|section| &section.items)
                .all(|item| item.id != ITEM_FOLDER),
            "the choice replaces the read-only folder"
        );
        let choice = item(&offered, ITEM_FOLDER_CHOICE);
        assert_eq!(choice.label.as_deref(), Some("Folder"));
        assert!(!choice.disabled);
        let BotChatSettingsControl::Select { value, options } = &choice.control else {
            panic!("folder select");
        };
        assert_eq!(value, "workspace-inline");
        let values: Vec<&str> = options.iter().map(|option| option.value.as_str()).collect();
        assert_eq!(values, ["workspace-inline", "workspace-secret-sauce"]);
        assert!(options.iter().all(|option| !option.disabled));

        let fixed = document(&DocumentFacts {
            folder_fixed: true,
            ..open
        });
        let choice = item(&fixed, ITEM_FOLDER_CHOICE);
        assert!(choice.disabled);
        assert_eq!(
            choice.disabled_reason.as_deref(),
            Some(
                "This thread's session works in inline. Start a new thread to work in another folder."
            )
        );
        let BotChatSettingsControl::Select { value, options } = &choice.control else {
            panic!("folder select");
        };
        assert_eq!(value, "workspace-inline", "the folder still shows");
        assert!(options.iter().all(|option| option.disabled));
        assert_ne!(offered.revision, fixed.revision);
    }

    #[test]
    fn a_folder_outside_the_list_shows_as_itself() {
        let catalog = catalog();
        let settings = SettingsChange::default();
        let folders = folders();
        let document = document(&DocumentFacts {
            folder_label: "scratch",
            folders: &folders,
            ..facts(&catalog, &settings)
        });
        let BotChatSettingsControl::Select { value, options } =
            &item(&document, ITEM_FOLDER_CHOICE).control
        else {
            panic!("folder select");
        };
        assert_eq!(value, CURRENT_FOLDER_VALUE);
        assert_eq!(options[0].label, "scratch");
        assert!(options[0].disabled);
        assert_eq!(options.len(), 3);
    }

    #[test]
    fn a_folder_invocation_names_its_choice() {
        let catalog = catalog();
        let value = |text: &str| BotSettingsValue::String(text.to_owned());
        assert_eq!(
            invocation(
                ITEM_FOLDER_CHOICE,
                Some(&value("workspace-inline")),
                &catalog
            ),
            Ok(Invocation::Folder("workspace-inline".to_owned()))
        );
        assert!(
            invocation(
                ITEM_FOLDER_CHOICE,
                Some(&value(CURRENT_FOLDER_VALUE)),
                &catalog
            )
            .is_err()
        );
        assert!(invocation(ITEM_FOLDER_CHOICE, None, &catalog).is_err());
    }

    #[test]
    fn a_folder_reaches_the_session_only_when_it_opens() {
        let mut settings = SettingsChange::default();
        merge(
            &mut settings,
            &SettingsChange {
                folder: Some("/work/inline".into()),
                ..SettingsChange::default()
            },
        );
        assert_eq!(settings.folder.as_deref(), Some(Path::new("/work/inline")));
        assert!(effective(&settings).is_empty());
    }

    #[test]
    fn a_model_without_efforts_hides_reasoning_and_the_revision_follows_choices() {
        let catalog = catalog();
        let default = SettingsChange::default();
        let luna = SettingsChange {
            model: Some("luna".to_owned()),
            ..SettingsChange::default()
        };
        let first = document(&facts(&catalog, &default));
        let second = document(&facts(&catalog, &luna));
        assert!(
            second
                .sections
                .iter()
                .flat_map(|section| &section.items)
                .all(|item| item.id != ITEM_REASONING)
        );
        assert_ne!(first.revision, second.revision);
    }

    #[test]
    fn invocations_stay_inside_the_catalog_and_default_clears() {
        let catalog = catalog();
        let value = |text: &str| BotSettingsValue::String(text.to_owned());
        assert_eq!(
            invocation(ITEM_MODEL, Some(&value("luna")), &catalog),
            Ok(Invocation::Change(SettingsChange {
                model: Some("luna".to_owned()),
                ..SettingsChange::default()
            }))
        );
        assert!(invocation(ITEM_MODEL, Some(&value("gpt-9")), &catalog).is_err());
        assert!(invocation(ITEM_REASONING, Some(&value("ultra")), &catalog).is_err());
        assert!(invocation("agent.secret", Some(&value("x")), &catalog).is_err());
        assert_eq!(
            invocation(ITEM_COMPACT, None, &catalog),
            Ok(Invocation::Compact)
        );
        let Ok(Invocation::Change(clear)) =
            invocation(ITEM_PERMISSIONS, Some(&value(DEFAULT_VALUE)), &catalog)
        else {
            panic!("clear");
        };
        let mut settings = SettingsChange {
            permission_mode: Some("default".to_owned()),
            ..SettingsChange::default()
        };
        merge(&mut settings, &clear);
        assert_eq!(settings.permission_mode, None);
        assert_eq!(effective(&clear).permission_mode, None);
    }

    #[test]
    fn the_catalog_capability_lists_folders_models_and_their_efforts() {
        let folders = AgentProjectCatalog {
            options: Vec::new(),
            can_select_folder: None,
            default_project_id: Some("workspace-inline".to_owned()),
        };
        let capabilities = capabilities(&catalog(), Some(folders.clone()));
        let configuration = capabilities
            .iter()
            .find_map(|capability| capability.agent_configuration.clone())
            .unwrap();
        assert_eq!(configuration.projects, Some(folders));
        let models = configuration.models.unwrap();
        assert_eq!(models.default_model_id.as_deref(), Some("sol"));
        assert_eq!(models.options[0].reasoning_effort_ids, ["low", "high"]);
        assert_eq!(configuration.reasoning.unwrap().options.len(), 2);
    }

    #[test]
    fn a_bound_choice_the_machine_lacks_falls_back_to_the_default() {
        let change = bound(Some("luna".to_owned()), Some("high".to_owned()), &catalog());
        assert_eq!(change.model.as_deref(), Some("luna"));
        assert_eq!(change.effort.as_deref(), Some("high"));
        let change = bound(Some("gone".to_owned()), Some("max".to_owned()), &catalog());
        assert_eq!(change.model.as_deref(), Some(""));
        assert_eq!(change.effort.as_deref(), Some(""));
        assert_eq!(bound(None, None, &catalog()).model.as_deref(), Some(""));
    }
}
