//! Protobuf conversion boundary for bot capabilities and chat settings.

use inline_sdk::proto;

use crate::{
    AgentConfigurationCatalog, AgentModelCatalog, AgentModelOption, AgentProjectCatalog,
    AgentProjectOption, AgentReasoningCatalog, AgentReasoningEffortOption, BackendError,
    BackendResult, BotCapability, BotCapabilityKind, BotChatSettingsControl,
    BotChatSettingsDocument, BotChatSettingsFolder, BotChatSettingsFolderOption,
    BotChatSettingsInfoTone, BotChatSettingsItem, BotChatSettingsProblem,
    BotChatSettingsProblemCode, BotChatSettingsResponse, BotChatSettingsSection,
    BotChatSettingsSelectOption, BotSettingsValue, ClientErrorCategory,
};

pub(super) fn capability_to_proto(capability: BotCapability) -> proto::BotCapability {
    proto::BotCapability {
        kind: match capability.kind {
            BotCapabilityKind::ChatSettings => proto::bot_capability::Kind::ChatSettings as i32,
            BotCapabilityKind::AgentConfiguration => {
                proto::bot_capability::Kind::AgentConfiguration as i32
            }
        },
        version: capability.version,
        agent_configuration: capability.agent_configuration.map(catalog_to_proto),
    }
}

pub(super) fn capability_from_proto(
    capability: proto::BotCapability,
) -> BackendResult<BotCapability> {
    let kind = match proto::bot_capability::Kind::try_from(capability.kind) {
        Ok(proto::bot_capability::Kind::ChatSettings) => BotCapabilityKind::ChatSettings,
        Ok(proto::bot_capability::Kind::AgentConfiguration) => {
            BotCapabilityKind::AgentConfiguration
        }
        _ => {
            return Err(protocol_mismatch(
                "server returned an unknown bot capability",
            ));
        }
    };
    if capability.version == 0 {
        return Err(protocol_mismatch(
            "server returned a bot capability with version zero",
        ));
    }
    Ok(BotCapability {
        kind,
        version: capability.version,
        agent_configuration: capability.agent_configuration.map(catalog_from_proto),
    })
}

fn catalog_to_proto(catalog: AgentConfigurationCatalog) -> proto::AgentConfigurationCatalog {
    proto::AgentConfigurationCatalog {
        projects: catalog.projects.map(|projects| proto::AgentProjectCatalog {
            options: projects
                .options
                .into_iter()
                .map(|option| proto::AgentProjectOption {
                    id: option.id,
                    label: option.label,
                    description: option.description,
                })
                .collect(),
            can_select_folder: projects.can_select_folder,
            default_project_id: projects.default_project_id,
        }),
        models: catalog.models.map(|models| proto::AgentModelCatalog {
            options: models
                .options
                .into_iter()
                .map(|option| proto::AgentModelOption {
                    id: option.id,
                    label: option.label,
                    description: option.description,
                    reasoning_effort_ids: option.reasoning_effort_ids,
                    default_reasoning_effort_id: option.default_reasoning_effort_id,
                })
                .collect(),
            default_model_id: models.default_model_id,
        }),
        reasoning: catalog
            .reasoning
            .map(|reasoning| proto::AgentReasoningCatalog {
                options: reasoning
                    .options
                    .into_iter()
                    .map(|option| proto::AgentReasoningEffortOption {
                        id: option.id,
                        label: option.label,
                        description: option.description,
                    })
                    .collect(),
            }),
    }
}

fn catalog_from_proto(catalog: proto::AgentConfigurationCatalog) -> AgentConfigurationCatalog {
    AgentConfigurationCatalog {
        projects: catalog.projects.map(|projects| AgentProjectCatalog {
            options: projects
                .options
                .into_iter()
                .map(|option| AgentProjectOption {
                    id: option.id,
                    label: option.label,
                    description: option.description,
                })
                .collect(),
            can_select_folder: projects.can_select_folder,
            default_project_id: projects.default_project_id,
        }),
        models: catalog.models.map(|models| AgentModelCatalog {
            options: models
                .options
                .into_iter()
                .map(|option| AgentModelOption {
                    id: option.id,
                    label: option.label,
                    description: option.description,
                    reasoning_effort_ids: option.reasoning_effort_ids,
                    default_reasoning_effort_id: option.default_reasoning_effort_id,
                })
                .collect(),
            default_model_id: models.default_model_id,
        }),
        reasoning: catalog.reasoning.map(|reasoning| AgentReasoningCatalog {
            options: reasoning
                .options
                .into_iter()
                .map(|option| AgentReasoningEffortOption {
                    id: option.id,
                    label: option.label,
                    description: option.description,
                })
                .collect(),
        }),
    }
}

pub(super) fn value_to_proto(value: BotSettingsValue) -> proto::BotChatSettingsValue {
    use proto::bot_chat_settings_value::Value;
    proto::BotChatSettingsValue {
        value: Some(match value {
            BotSettingsValue::Bool(value) => Value::BoolValue(value),
            BotSettingsValue::String(value) => Value::StringValue(value),
        }),
    }
}

pub(super) fn response_to_proto(
    response: BotChatSettingsResponse,
) -> proto::BotChatSettingsResponse {
    use proto::bot_chat_settings_response::Result;
    proto::BotChatSettingsResponse {
        result: Some(match response {
            BotChatSettingsResponse::Document(document) => {
                Result::Document(document_to_proto(document))
            }
            BotChatSettingsResponse::Problem(problem) => Result::Problem(problem_to_proto(problem)),
        }),
    }
}

pub(super) fn response_from_proto(
    response: Option<proto::BotChatSettingsResponse>,
) -> BackendResult<BotChatSettingsResponse> {
    use proto::bot_chat_settings_response::Result;
    match response.and_then(|response| response.result) {
        Some(Result::Document(document)) => {
            document_from_proto(document).map(BotChatSettingsResponse::Document)
        }
        Some(Result::Problem(problem)) => {
            problem_from_proto(problem).map(BotChatSettingsResponse::Problem)
        }
        None => Err(protocol_mismatch(
            "bot settings response omitted its result",
        )),
    }
}

fn document_to_proto(document: BotChatSettingsDocument) -> proto::BotChatSettingsDocument {
    proto::BotChatSettingsDocument {
        version: document.version,
        revision: document.revision,
        sections: document
            .sections
            .into_iter()
            .map(section_to_proto)
            .collect(),
    }
}

fn document_from_proto(
    document: proto::BotChatSettingsDocument,
) -> BackendResult<BotChatSettingsDocument> {
    if document.version == 0 || document.revision.trim().is_empty() {
        return Err(protocol_mismatch(
            "bot settings document omitted its version or revision",
        ));
    }
    Ok(BotChatSettingsDocument {
        version: document.version,
        revision: document.revision,
        sections: document
            .sections
            .into_iter()
            .map(section_from_proto)
            .collect::<BackendResult<_>>()?,
    })
}

fn section_to_proto(section: BotChatSettingsSection) -> proto::BotChatSettingsSection {
    proto::BotChatSettingsSection {
        id: section.id,
        title: section.title,
        description: section.description,
        items: section.items.into_iter().map(item_to_proto).collect(),
    }
}

fn section_from_proto(
    section: proto::BotChatSettingsSection,
) -> BackendResult<BotChatSettingsSection> {
    if section.id.trim().is_empty() {
        return Err(protocol_mismatch("bot settings section omitted its ID"));
    }
    Ok(BotChatSettingsSection {
        id: section.id,
        title: section.title,
        description: section.description,
        items: section
            .items
            .into_iter()
            .map(item_from_proto)
            .collect::<BackendResult<_>>()?,
    })
}

fn item_to_proto(item: BotChatSettingsItem) -> proto::BotChatSettingsItem {
    use proto::bot_chat_settings_item::Control;
    let control = match item.control {
        BotChatSettingsControl::Toggle { value } => {
            Control::Toggle(proto::BotChatSettingsToggle { value })
        }
        BotChatSettingsControl::Select { value, options } => {
            Control::Select(proto::BotChatSettingsSelect {
                value,
                options: options.into_iter().map(select_option_to_proto).collect(),
            })
        }
        BotChatSettingsControl::Info { text, tone } => Control::Info(proto::BotChatSettingsInfo {
            text,
            tone: info_tone_to_proto(tone) as i32,
        }),
        BotChatSettingsControl::Button => Control::Button(proto::BotChatSettingsButton {}),
        BotChatSettingsControl::Folder(folder) => Control::Folder(folder_to_proto(folder)),
    };
    proto::BotChatSettingsItem {
        id: item.id,
        label: item.label,
        description: item.description,
        disabled: item.disabled,
        disabled_reason: item.disabled_reason,
        control: Some(control),
    }
}

fn item_from_proto(item: proto::BotChatSettingsItem) -> BackendResult<BotChatSettingsItem> {
    use proto::bot_chat_settings_item::Control;
    if item.id.trim().is_empty() {
        return Err(protocol_mismatch("bot settings item omitted its ID"));
    }
    let control = match item.control {
        Some(Control::Toggle(toggle)) => BotChatSettingsControl::Toggle {
            value: toggle.value,
        },
        Some(Control::Select(select)) => BotChatSettingsControl::Select {
            value: select.value,
            options: select
                .options
                .into_iter()
                .map(select_option_from_proto)
                .collect::<BackendResult<_>>()?,
        },
        Some(Control::Info(info)) => BotChatSettingsControl::Info {
            text: info.text,
            tone: info_tone_from_proto(info.tone)?,
        },
        Some(Control::Button(_)) => BotChatSettingsControl::Button,
        Some(Control::Folder(folder)) => BotChatSettingsControl::Folder(folder_from_proto(folder)?),
        None => return Err(protocol_mismatch("bot settings item omitted its control")),
    };
    Ok(BotChatSettingsItem {
        id: item.id,
        label: item.label,
        description: item.description,
        disabled: item.disabled,
        disabled_reason: item.disabled_reason,
        control,
    })
}

fn select_option_to_proto(
    option: BotChatSettingsSelectOption,
) -> proto::BotChatSettingsSelectOption {
    proto::BotChatSettingsSelectOption {
        value: option.value,
        label: option.label,
        description: option.description,
        disabled: option.disabled,
    }
}

fn select_option_from_proto(
    option: proto::BotChatSettingsSelectOption,
) -> BackendResult<BotChatSettingsSelectOption> {
    if option.value.trim().is_empty() || option.label.trim().is_empty() {
        return Err(protocol_mismatch(
            "bot settings select option omitted its value or label",
        ));
    }
    Ok(BotChatSettingsSelectOption {
        value: option.value,
        label: option.label,
        description: option.description,
        disabled: option.disabled,
    })
}

fn info_tone_to_proto(tone: BotChatSettingsInfoTone) -> proto::bot_chat_settings_info::Tone {
    match tone {
        BotChatSettingsInfoTone::Neutral => proto::bot_chat_settings_info::Tone::Neutral,
        BotChatSettingsInfoTone::Success => proto::bot_chat_settings_info::Tone::Success,
        BotChatSettingsInfoTone::Warning => proto::bot_chat_settings_info::Tone::Warning,
        BotChatSettingsInfoTone::Error => proto::bot_chat_settings_info::Tone::Error,
    }
}

fn info_tone_from_proto(value: i32) -> BackendResult<BotChatSettingsInfoTone> {
    match proto::bot_chat_settings_info::Tone::try_from(value) {
        Ok(proto::bot_chat_settings_info::Tone::Neutral) => Ok(BotChatSettingsInfoTone::Neutral),
        Ok(proto::bot_chat_settings_info::Tone::Success) => Ok(BotChatSettingsInfoTone::Success),
        Ok(proto::bot_chat_settings_info::Tone::Warning) => Ok(BotChatSettingsInfoTone::Warning),
        Ok(proto::bot_chat_settings_info::Tone::Error) => Ok(BotChatSettingsInfoTone::Error),
        _ => Err(protocol_mismatch("bot settings info used an unknown tone")),
    }
}

fn folder_to_proto(folder: BotChatSettingsFolder) -> proto::BotChatSettingsFolder {
    proto::BotChatSettingsFolder {
        value: folder.value,
        recent_folders: folder
            .recent_folders
            .into_iter()
            .map(folder_option_to_proto)
            .collect(),
        host_installation_id: folder.host_installation_id,
        host_label: folder.host_label,
        allows_local_picker: folder.allows_local_picker,
        local_picker_port: folder.local_picker_port,
        local_picker_capability: folder.local_picker_capability,
    }
}

fn folder_from_proto(folder: proto::BotChatSettingsFolder) -> BackendResult<BotChatSettingsFolder> {
    if folder.host_installation_id.trim().is_empty() || folder.host_label.trim().is_empty() {
        return Err(protocol_mismatch(
            "bot settings folder omitted its host identity",
        ));
    }
    Ok(BotChatSettingsFolder {
        value: folder.value,
        recent_folders: folder
            .recent_folders
            .into_iter()
            .map(folder_option_from_proto)
            .collect::<BackendResult<_>>()?,
        host_installation_id: folder.host_installation_id,
        host_label: folder.host_label,
        allows_local_picker: folder.allows_local_picker,
        local_picker_port: folder.local_picker_port,
        local_picker_capability: folder.local_picker_capability,
    })
}

fn folder_option_to_proto(
    option: BotChatSettingsFolderOption,
) -> proto::BotChatSettingsFolderOption {
    proto::BotChatSettingsFolderOption {
        value: option.value,
        label: option.label,
        parent_hint: option.parent_hint,
        disabled: option.disabled,
    }
}

fn folder_option_from_proto(
    option: proto::BotChatSettingsFolderOption,
) -> BackendResult<BotChatSettingsFolderOption> {
    if option.value.trim().is_empty() || option.label.trim().is_empty() {
        return Err(protocol_mismatch(
            "bot settings folder option omitted its value or label",
        ));
    }
    Ok(BotChatSettingsFolderOption {
        value: option.value,
        label: option.label,
        parent_hint: option.parent_hint,
        disabled: option.disabled,
    })
}

fn problem_to_proto(problem: BotChatSettingsProblem) -> proto::BotChatSettingsProblem {
    proto::BotChatSettingsProblem {
        code: problem_code_to_proto(problem.code) as i32,
        message: problem.message,
        current_document: problem.current_document.map(document_to_proto),
    }
}

fn problem_from_proto(
    problem: proto::BotChatSettingsProblem,
) -> BackendResult<BotChatSettingsProblem> {
    Ok(BotChatSettingsProblem {
        code: problem_code_from_proto(problem.code)?,
        message: problem.message,
        current_document: problem
            .current_document
            .map(document_from_proto)
            .transpose()?,
    })
}

fn problem_code_to_proto(
    code: BotChatSettingsProblemCode,
) -> proto::bot_chat_settings_problem::Code {
    match code {
        BotChatSettingsProblemCode::Unavailable => {
            proto::bot_chat_settings_problem::Code::Unavailable
        }
        BotChatSettingsProblemCode::InvalidValue => {
            proto::bot_chat_settings_problem::Code::InvalidValue
        }
        BotChatSettingsProblemCode::Stale => proto::bot_chat_settings_problem::Code::Stale,
        BotChatSettingsProblemCode::Failed => proto::bot_chat_settings_problem::Code::Failed,
        BotChatSettingsProblemCode::Unreachable => {
            proto::bot_chat_settings_problem::Code::Unreachable
        }
    }
}

fn problem_code_from_proto(value: i32) -> BackendResult<BotChatSettingsProblemCode> {
    match proto::bot_chat_settings_problem::Code::try_from(value) {
        Ok(proto::bot_chat_settings_problem::Code::Unavailable) => {
            Ok(BotChatSettingsProblemCode::Unavailable)
        }
        Ok(proto::bot_chat_settings_problem::Code::InvalidValue) => {
            Ok(BotChatSettingsProblemCode::InvalidValue)
        }
        Ok(proto::bot_chat_settings_problem::Code::Stale) => Ok(BotChatSettingsProblemCode::Stale),
        Ok(proto::bot_chat_settings_problem::Code::Failed) => {
            Ok(BotChatSettingsProblemCode::Failed)
        }
        Ok(proto::bot_chat_settings_problem::Code::Unreachable) => {
            Ok(BotChatSettingsProblemCode::Unreachable)
        }
        _ => Err(protocol_mismatch(
            "bot settings problem used an unknown code",
        )),
    }
}

fn protocol_mismatch(message: &'static str) -> BackendError {
    BackendError::new(ClientErrorCategory::ProtocolMismatch, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_round_trip_preserves_named_agent_defaults() {
        let capability = BotCapability {
            kind: BotCapabilityKind::AgentConfiguration,
            version: 1,
            agent_configuration: Some(AgentConfigurationCatalog {
                projects: Some(AgentProjectCatalog {
                    options: vec![AgentProjectOption {
                        id: "inline".to_owned(),
                        label: "Inline".to_owned(),
                        description: None,
                    }],
                    can_select_folder: None,
                    default_project_id: Some("inline".to_owned()),
                }),
                models: Some(AgentModelCatalog {
                    options: vec![AgentModelOption {
                        id: "gpt-test".to_owned(),
                        label: "GPT Test".to_owned(),
                        description: None,
                        reasoning_effort_ids: vec!["high".to_owned()],
                        default_reasoning_effort_id: Some("high".to_owned()),
                    }],
                    default_model_id: Some("gpt-test".to_owned()),
                }),
                reasoning: Some(AgentReasoningCatalog {
                    options: vec![AgentReasoningEffortOption {
                        id: "high".to_owned(),
                        label: "High".to_owned(),
                        description: None,
                    }],
                }),
            }),
        };

        assert_eq!(
            capability_from_proto(capability_to_proto(capability.clone())).unwrap(),
            capability
        );
    }

    #[test]
    fn response_round_trip_preserves_folder_metadata_without_paths() {
        let response = BotChatSettingsResponse::Document(BotChatSettingsDocument {
            version: 1,
            revision: "rev-1".to_owned(),
            sections: vec![BotChatSettingsSection {
                id: "workspace".to_owned(),
                title: Some("Workspace".to_owned()),
                description: None,
                items: vec![BotChatSettingsItem {
                    id: "folder".to_owned(),
                    label: Some("Folder".to_owned()),
                    description: None,
                    disabled: false,
                    disabled_reason: None,
                    control: BotChatSettingsControl::Folder(BotChatSettingsFolder {
                        value: "workspace-1".to_owned(),
                        recent_folders: vec![BotChatSettingsFolderOption {
                            value: "workspace-1".to_owned(),
                            label: "inline".to_owned(),
                            parent_hint: Some("projects".to_owned()),
                            disabled: false,
                        }],
                        host_installation_id: "host-1".to_owned(),
                        host_label: "Mo's Mac".to_owned(),
                        allows_local_picker: true,
                        local_picker_port: Some(51_234),
                        local_picker_capability: Some(
                            "capability-0123456789abcdef0123456789abcdef".to_owned(),
                        ),
                    }),
                }],
            }],
        });

        assert_eq!(
            response_from_proto(Some(response_to_proto(response.clone()))).unwrap(),
            response
        );
    }

    #[test]
    fn empty_result_is_a_protocol_mismatch() {
        let error = response_from_proto(Some(proto::BotChatSettingsResponse { result: None }))
            .expect_err("missing result must fail");
        assert_eq!(error.category, ClientErrorCategory::ProtocolMismatch);
    }
}
