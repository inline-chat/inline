//! Pickers and commands from the OpenCode service.
//!
//! | Inline | OpenCode |
//! | --- | --- |
//! | models, efforts | `GET /api/model` (enabled models; `variants` are reasoning levels), `GET /api/model/default` |
//! | modes | primary agents from `GET /api/agent` (`build`, `plan`, ...) |
//! | agents | subagents from `GET /api/agent` |
//! | commands | `GET /api/command` |
//! | skills | `GET /api/skill` |
//! | permission modes | Inline presets over OpenCode's session permission rules |
//! | folders | `GET /api/project` |
//! | usage | `GET /api/experimental/usage/limits` (OpenCode Go meters, budgets) |
//!
//! A model value is OpenCode's own reference form, `providerID/id`, and an
//! effort is a variant id: `providerID/id#variant` is what OpenCode itself
//! accepts.

use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::{Catalog, CatalogFolder, CatalogMode, ModeId};
use inline_agent_bridge::{
    DriverCommand, DriverCommandInput, DriverModelOption, DriverSettingOption, DriverUsageWindow,
};
use serde_json::{Value, json};

use crate::api::{Api, ApiError, Query, data};

/// Permission preset: OpenCode's own rules (agent rules, config, saved
/// approvals). OpenCode's agents allow everything but `.env` reads by default,
/// and the plan agent denies edits.
pub const PERMISSION_DEFAULT: &str = "default";
/// Permission preset: ask before edits, shell commands and fetches.
pub const PERMISSION_ASK: &str = "ask";

/// The permission presets Inline offers.
pub fn permission_modes() -> Vec<DriverSettingOption> {
    vec![
        option(
            PERMISSION_DEFAULT,
            "OpenCode rules",
            Some("Follow OpenCode's agent and configured permissions"),
        ),
        option(
            PERMISSION_ASK,
            "Ask first",
            Some("Ask before edits, shell commands and web fetches"),
        ),
    ]
}

/// The session permission ruleset for a preset; `None` for an unknown preset.
///
/// OpenCode evaluates agent rules, then session rules, and the last match
/// wins; `PATCH /api/session/{id}` replaces the session rules. An empty
/// ruleset leaves OpenCode's own. There is deliberately no blanket allow:
/// a session `*` rule would override the plan agent's edit deny.
pub fn permission_rules(mode: &str) -> Option<Value> {
    match mode {
        PERMISSION_DEFAULT => Some(json!([])),
        PERMISSION_ASK => Some(json!([
            {"action": "edit", "resource": "*", "effect": "ask"},
            {"action": "shell", "resource": "*", "effect": "ask"},
            {"action": "webfetch", "resource": "*", "effect": "ask"},
        ])),
        _ => None,
    }
}

fn option(value: &str, label: &str, description: Option<&str>) -> DriverSettingOption {
    DriverSettingOption {
        value: value.to_owned(),
        label: label.to_owned(),
        description: description.map(str::to_owned),
        disabled: false,
    }
}

/// Parses `providerID/id` (optionally `#variant`) into an OpenCode model ref.
pub fn model_ref(value: &str, effort: Option<&str>) -> Option<Value> {
    let (provider, rest) = value.split_once('/')?;
    let (id, variant) = match rest.split_once('#') {
        Some((id, variant)) => (id, Some(variant)),
        None => (rest, None),
    };
    if provider.is_empty() || id.is_empty() {
        return None;
    }
    let mut reference = json!({"providerID": provider, "id": id});
    if let Some(variant) = effort.or(variant).filter(|variant| !variant.is_empty()) {
        reference["variant"] = json!(variant);
    }
    Some(reference)
}

/// `providerID/id` for an OpenCode model ref.
pub fn model_value(reference: &Value) -> Option<String> {
    let provider = reference.get("providerID")?.as_str()?;
    let id = reference.get("id")?.as_str()?;
    Some(format!("{provider}/{id}"))
}

/// Reads the whole catalog for a folder. Each part degrades on its own: a
/// failing listing leaves its picker empty rather than failing the catalog.
pub async fn read(api: &Api, folder: Option<&Path>) -> Result<Catalog, ApiError> {
    let query = || Query::new().location(folder);
    let (models, default, agents, commands, skills, projects, usage) = tokio::join!(
        api.get("api/model", query()),
        api.get("api/model/default", query()),
        api.get("api/agent", query()),
        api.get("api/command", query()),
        api.get("api/skill", query()),
        api.get("api/project", Query::new()),
        api.get("api/experimental/usage/limits", query()),
    );
    // The model list is the one part a catalog cannot do without.
    let models = models?;
    // A folder OpenCode has not loaded yet answers before its plugins
    // (which define commands, built-ins included) activate.
    let mut commands = commands.map(data).unwrap_or_default();
    for _ in 0..3 {
        if commands
            .as_array()
            .is_some_and(|commands| !commands.is_empty())
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        commands = api
            .get("api/command", query())
            .await
            .map(data)
            .unwrap_or_default();
    }
    let default = default.ok().map(data).and_then(|model| {
        Some(format!(
            "{}/{}",
            model.get("providerID")?.as_str()?,
            model.get("id")?.as_str()?
        ))
    });
    let agents = agents.map(data).unwrap_or_default();
    Ok(Catalog {
        models: models_from(&data(models), default.as_deref()),
        speeds: Vec::new(),
        permission_modes: permission_modes(),
        modes: modes_from(&agents),
        commands: commands_from(&commands),
        agents: subagents_from(&agents),
        skills: skills_from(&skills.map(data).unwrap_or_default()),
        folders: folders_from(&projects.map(data).unwrap_or_default()),
        usage: usage_from(&usage.map(data).unwrap_or_default()),
    })
}

/// Enabled, non-deprecated language models, default first.
pub fn models_from(models: &Value, default: Option<&str>) -> Vec<DriverModelOption> {
    let mut options: Vec<DriverModelOption> = models
        .as_array()
        .into_iter()
        .flatten()
        .filter(|model| {
            model
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        })
        .filter(|model| model.get("status").and_then(Value::as_str) != Some("deprecated"))
        .filter(|model| {
            // Image, embedding and speech models cannot run a session.
            model
                .get("type")
                .and_then(Value::as_str)
                .is_none_or(|kind| kind == "language" || kind == "chat" || kind == "text")
        })
        .filter_map(|model| {
            let provider = model.get("providerID")?.as_str()?;
            let id = model.get("id")?.as_str()?;
            let value = format!("{provider}/{id}");
            let name = model.get("name").and_then(Value::as_str).unwrap_or(id);
            let reasoning: Vec<DriverSettingOption> = model
                .get("variants")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|variant| variant.get("id")?.as_str())
                .map(|variant| option(variant, &title_case(variant), None))
                .collect();
            Some(DriverModelOption {
                is_default: default == Some(value.as_str()),
                label: format!("{name} ({provider})"),
                description: model
                    .pointer("/limit/context")
                    .and_then(Value::as_u64)
                    .filter(|context| *context > 0)
                    .map(|context| format!("{}k context", context / 1000)),
                reasoning,
                default_reasoning: None,
                value,
            })
        })
        .collect();
    options.sort_by_key(|model| !model.is_default);
    options
}

/// Context window of one model, from the model listing.
pub fn context_window(models: &Value, value: &str) -> Option<u64> {
    models.as_array()?.iter().find_map(|model| {
        let candidate = format!(
            "{}/{}",
            model.get("providerID")?.as_str()?,
            model.get("id")?.as_str()?
        );
        (candidate == value)
            .then(|| model.pointer("/limit/context").and_then(Value::as_u64))
            .flatten()
    })
}

fn visible_agents<'a>(agents: &'a Value, primary: bool) -> impl Iterator<Item = &'a Value> + 'a {
    agents
        .as_array()
        .into_iter()
        .flatten()
        .filter(|agent| {
            !agent
                .get("hidden")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .filter(move |agent| {
            let mode = agent.get("mode").and_then(Value::as_str).unwrap_or("all");
            if primary {
                mode == "primary" || mode == "all"
            } else {
                mode == "subagent" || mode == "all"
            }
        })
}

/// Primary agents are OpenCode's modes (`build`, `plan`, ...).
pub fn modes_from(agents: &Value) -> Vec<CatalogMode> {
    visible_agents(agents, true)
        .filter_map(|agent| {
            let id = agent.get("id")?.as_str()?;
            Some(CatalogMode {
                id: ModeId::new(id).ok()?,
                label: agent
                    .get("name")
                    .and_then(Value::as_str)
                    .map_or_else(|| title_case(id), title_case),
                description: agent
                    .get("description")
                    .and_then(Value::as_str)
                    .map(|text| crate::api::bounded(text, 200)),
            })
        })
        .collect()
}

fn subagents_from(agents: &Value) -> Vec<DriverSettingOption> {
    visible_agents(agents, false)
        .filter_map(|agent| {
            let id = agent.get("id")?.as_str()?;
            Some(option(
                id,
                agent.get("name").and_then(Value::as_str).unwrap_or(id),
                agent
                    .get("description")
                    .and_then(Value::as_str)
                    .map(|text| crate::api::bounded(text, 200))
                    .as_deref(),
            ))
        })
        .collect()
}

fn commands_from(commands: &Value) -> Vec<DriverCommand> {
    commands
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|command| {
            let name = command.get("name")?.as_str()?.trim_start_matches('/');
            if name.is_empty() || name.contains(char::is_whitespace) {
                return None;
            }
            Some(DriverCommand {
                name: name.to_owned(),
                description: command
                    .get("description")
                    .and_then(Value::as_str)
                    .map(|text| crate::api::bounded(text, 200))
                    .unwrap_or_default(),
                input_hint: None,
                input: DriverCommandInput::Freeform {
                    hint: String::new(),
                    required: false,
                },
            })
        })
        .collect()
}

fn skills_from(skills: &Value) -> Vec<DriverSettingOption> {
    skills
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|skill| {
            let id = skill.get("id")?.as_str()?;
            Some(option(
                id,
                skill.get("name").and_then(Value::as_str).unwrap_or(id),
                skill
                    .get("description")
                    .and_then(Value::as_str)
                    .map(|text| crate::api::bounded(text, 200))
                    .as_deref(),
            ))
        })
        .collect()
}

fn folders_from(projects: &Value) -> Vec<CatalogFolder> {
    let mut projects: Vec<&Value> = projects
        .as_array()
        .into_iter()
        .flatten()
        .filter(|project| project.pointer("/time/archived").is_none())
        .collect();
    // Most recently active first, as OpenCode's own project list.
    projects.sort_by_key(|project| {
        std::cmp::Reverse(
            project
                .pointer("/time/active")
                .and_then(Value::as_i64)
                .unwrap_or(0),
        )
    });
    projects
        .into_iter()
        .filter_map(|project| {
            let path = PathBuf::from(project.get("canonical")?.as_str()?);
            if !path.is_absolute() || path == Path::new("/") {
                return None;
            }
            let label = project
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| {
                    path.file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                })?;
            Some(CatalogFolder { path, label })
        })
        .take(50)
        .collect()
}

/// OpenCode Go meters and budgets as usage windows.
pub fn usage_from(limits: &Value) -> Vec<DriverUsageWindow> {
    let mut windows = Vec::new();
    for (key, label, minutes) in [
        ("rolling", "5-hour", Some(300)),
        ("weekly", "Weekly", Some(7 * 24 * 60)),
        ("monthly", "Monthly", None),
    ] {
        if let Some(meter) = limits.pointer(&format!("/go/{key}")) {
            windows.push(DriverUsageWindow {
                label: format!("Go {label}"),
                used_percent: percent(meter.get("percent").and_then(Value::as_f64).unwrap_or(0.0)),
                window_minutes: minutes,
                resets_at: meter
                    .get("resetsAt")
                    .and_then(Value::as_i64)
                    .map(milliseconds_to_seconds),
            });
        }
    }
    for budget in limits
        .get("budgets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|budget| {
            budget
                .get("picked")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        })
    {
        let limit = budget.get("limit").and_then(Value::as_f64).unwrap_or(0.0);
        let spent = budget.get("spent").and_then(Value::as_f64).unwrap_or(0.0);
        if limit <= 0.0 {
            continue;
        }
        windows.push(DriverUsageWindow {
            label: format!("Budget ${limit:.0}"),
            used_percent: percent(spent / limit * 100.0),
            window_minutes: None,
            resets_at: budget
                .get("resetsAt")
                .and_then(Value::as_i64)
                .map(milliseconds_to_seconds),
        });
    }
    windows
}

fn percent(value: f64) -> u8 {
    if value.is_nan() {
        return 0;
    }
    value.clamp(0.0, 100.0).round() as u8
}

/// OpenCode timestamps are milliseconds; tolerate seconds.
pub fn milliseconds_to_seconds(value: i64) -> i64 {
    if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    }
}

/// `deep-think` → `Deep think`.
pub fn title_case(text: &str) -> String {
    let text = text.replace(['-', '_'], " ");
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_refs_round_trip_opencode_reference_form() {
        assert_eq!(
            model_ref("anthropic/claude-sonnet-5", Some("high")).unwrap(),
            json!({"providerID": "anthropic", "id": "claude-sonnet-5", "variant": "high"})
        );
        assert_eq!(
            model_ref("openai/gpt-6#low", None).unwrap(),
            json!({"providerID": "openai", "id": "gpt-6", "variant": "low"})
        );
        assert!(model_ref("nonsense", None).is_none());
        assert_eq!(
            model_value(&json!({"providerID": "a", "id": "b", "variant": "x"})).as_deref(),
            Some("a/b")
        );
    }

    #[test]
    fn models_keep_enabled_language_models_with_variants() {
        let models = json!([
            {"id": "m1", "providerID": "p", "name": "Model One", "enabled": true, "status": "active",
             "variants": [{"id": "low"}, {"id": "high"}], "limit": {"context": 200000, "output": 1}},
            {"id": "m2", "providerID": "p", "name": "Old", "enabled": true, "status": "deprecated", "variants": []},
            {"id": "m3", "providerID": "p", "name": "Off", "enabled": false, "variants": []},
            {"id": "img", "providerID": "p", "name": "Image", "type": "image", "variants": []},
            {"id": "m4", "providerID": "q", "name": "Four", "variants": []},
        ]);
        let options = models_from(&models, Some("q/m4"));
        assert_eq!(
            options
                .iter()
                .map(|model| model.value.as_str())
                .collect::<Vec<_>>(),
            vec!["q/m4", "p/m1"]
        );
        assert!(options[0].is_default);
        assert_eq!(options[1].reasoning.len(), 2);
        assert_eq!(options[1].description.as_deref(), Some("200k context"));
        assert_eq!(context_window(&models, "p/m1"), Some(200000));
    }

    #[test]
    fn agents_split_into_modes_and_subagents() {
        let agents = json!([
            {"id": "build", "name": "build", "mode": "primary", "hidden": false},
            {"id": "plan", "name": "plan", "mode": "primary", "hidden": false, "description": "Read only"},
            {"id": "general", "name": "general", "mode": "subagent", "hidden": false},
            {"id": "title", "name": "title", "mode": "primary", "hidden": true},
        ]);
        let modes = modes_from(&agents);
        assert_eq!(modes.len(), 2);
        assert_eq!(modes[1].label, "Plan");
        assert_eq!(subagents_from(&agents)[0].value, "general");
    }

    #[test]
    fn usage_reads_go_meters_and_budgets() {
        let limits = json!({
            "workspace": {"id": "w", "usageURL": "https://x"},
            "go": {
                "rolling": {"percent": 42.4, "limited": false, "resetsAt": 1_800_000_000_000i64},
                "weekly": {"percent": 101, "limited": true, "resetsAt": 1_800_000_000},
                "monthly": {"percent": 5, "limited": false, "resetsAt": 0}
            },
            "budgets": [{"id": "b", "limit": 20, "spent": 5, "picked": true, "resetsAt": 1_800_000_000_000i64}]
        });
        let windows = usage_from(&limits);
        assert_eq!(windows.len(), 4);
        assert_eq!(windows[0].used_percent, 42);
        assert_eq!(windows[0].resets_at, Some(1_800_000_000));
        assert_eq!(windows[1].used_percent, 100);
        assert_eq!(windows[3].used_percent, 25);
    }

    #[test]
    fn permission_presets_map_to_session_rules() {
        assert_eq!(
            permission_rules(PERMISSION_ASK).unwrap()[1]["action"],
            "shell"
        );
        assert_eq!(permission_rules(PERMISSION_DEFAULT).unwrap(), json!([]));
        assert!(permission_rules("bypassPermissions").is_none());
        assert_eq!(title_case("deep-think"), "Deep think");
    }
}
