//! Bot chat settings for v2 works: Agent Settings and the composer chain
//! (spec §6, decided Oct 26). Model, reasoning and permission mode come from
//! the harness's own catalog and apply to this thread's work from the next
//! message on. Item IDs match what the apps already read
//! (`ComposeAgentSettingsItem`).

use inline_agent_bridge::harness::{Catalog, SettingsChange};
use inline_client::{
    AgentConfigurationCatalog, AgentModelCatalog, AgentModelOption, AgentReasoningCatalog,
    AgentReasoningEffortOption, BotCapability, BotCapabilityKind, BotChatSettingsControl,
    BotChatSettingsDocument, BotChatSettingsInfoTone, BotChatSettingsItem, BotChatSettingsProblem,
    BotChatSettingsProblemCode, BotChatSettingsResponse, BotChatSettingsSection,
    BotChatSettingsSelectOption, BotSettingsValue,
};

pub(crate) const SETTINGS_VERSION: u32 = 1;
const AGENT_CONFIGURATION_VERSION: u32 = 1;

pub(crate) const ITEM_MODEL: &str = "agent.model";
pub(crate) const ITEM_REASONING: &str = "agent.reasoning";
pub(crate) const ITEM_PERMISSIONS: &str = "agent.permissions";
pub(crate) const ITEM_COMPACT: &str = "session.compact";
const ITEM_FOLDER: &str = "workspace.folder";
/// "Use the harness's default", as a select value.
const DEFAULT_VALUE: &str = "__inline_provider_default__";

/// What a settings invocation asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Invocation {
    Change(SettingsChange),
    Compact,
}

/// The capabilities that make the apps offer settings and the chain.
pub(crate) fn capabilities(catalog: &Catalog) -> Vec<BotCapability> {
    vec![
        BotCapability {
            kind: BotCapabilityKind::ChatSettings,
            version: SETTINGS_VERSION,
            agent_configuration: None,
        },
        BotCapability {
            kind: BotCapabilityKind::AgentConfiguration,
            version: AGENT_CONFIGURATION_VERSION,
            agent_configuration: Some(configuration_catalog(catalog)),
        },
    ]
}

/// Models and efforts as the apps' Agent configuration catalog.
pub(crate) fn configuration_catalog(catalog: &Catalog) -> AgentConfigurationCatalog {
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
        projects: None,
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

/// Where the document's facts come from.
pub(crate) struct DocumentFacts<'a> {
    pub catalog: &'a Catalog,
    /// This thread's choices; `None` fields are the harness's defaults.
    pub settings: &'a SettingsChange,
    pub folder_label: &'a str,
    pub machine_label: &'a str,
    /// A session is open, so it can be compacted now.
    pub can_compact: bool,
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
    let session = vec![BotChatSettingsItem {
        id: ITEM_COMPACT.to_owned(),
        label: Some("Compact context".to_owned()),
        description: Some("Summarize this thread's session to free context.".to_owned()),
        disabled: !facts.can_compact,
        disabled_reason: (!facts.can_compact)
            .then(|| "Nothing is open in this thread yet.".to_owned()),
        control: BotChatSettingsControl::Button,
    }];
    let workspace = vec![BotChatSettingsItem {
        id: ITEM_FOLDER.to_owned(),
        label: Some("Folder".to_owned()),
        description: None,
        disabled: false,
        disabled_reason: None,
        control: BotChatSettingsControl::Info {
            text: format!("{} on {}", facts.folder_label, facts.machine_label),
            tone: BotChatSettingsInfoTone::Neutral,
        },
    }];
    let sections = [
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
        "{}|{}|{}|{}|{}|{}",
        settings.model.as_deref().unwrap_or(""),
        settings.effort.as_deref().unwrap_or(""),
        settings.permission_mode.as_deref().unwrap_or(""),
        models.join(","),
        facts.can_compact,
        facts.folder_label,
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
/// the harness has no "back to default" for a running session.
pub(crate) fn effective(change: &SettingsChange) -> SettingsChange {
    let keep = |value: &Option<String>| value.clone().filter(|value| !value.is_empty());
    SettingsChange {
        model: keep(&change.model),
        effort: keep(&change.effort),
        speed: keep(&change.speed),
        permission_mode: keep(&change.permission_mode),
        folder: change.folder.clone(),
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

    fn facts<'a>(catalog: &'a Catalog, settings: &'a SettingsChange) -> DocumentFacts<'a> {
        DocumentFacts {
            catalog,
            settings,
            folder_label: "project",
            machine_label: "MacBook",
            can_compact: true,
        }
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
    fn the_catalog_capability_lists_models_and_their_efforts() {
        let capabilities = capabilities(&catalog());
        let configuration = capabilities
            .iter()
            .find_map(|capability| capability.agent_configuration.clone())
            .unwrap();
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
