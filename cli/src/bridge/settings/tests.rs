use std::path::Path;
use std::sync::Arc;

use inline_agent_bridge::{
    AgentEventReceiver, ApprovalDecision, DriverCapabilities, DriverError, DriverFuture,
    DriverModelOption, DriverSettingOption, ProviderSessionId, ResumeSessionSpec, SessionSpec,
    StartedTurn, TurnId,
};

use super::*;

#[derive(Clone, Copy, Debug)]
enum CatalogBehavior {
    Ready,
    Pending,
    ProcessExited,
}

#[derive(Debug)]
struct FakeDriver {
    catalog: CatalogBehavior,
    compact_session: bool,
}

impl AgentDriver for FakeDriver {
    fn capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            resume_session: true,
            compact_session: self.compact_session,
            settings_catalog: true,
            ..DriverCapabilities::default()
        }
    }

    fn settings_catalog<'a>(&'a self, _cwd: &'a Path) -> DriverFuture<'a, DriverSettingsCatalog> {
        Box::pin(async move {
            match self.catalog {
                CatalogBehavior::Ready => Ok(DriverSettingsCatalog {
                    models: vec![DriverModelOption {
                        value: "gpt-test".to_string(),
                        label: "GPT Test".to_string(),
                        description: None,
                        reasoning: vec![DriverSettingOption {
                            value: "high".to_string(),
                            label: "High".to_string(),
                            description: None,
                            disabled: false,
                        }],
                        default_reasoning: Some("high".to_string()),
                        is_default: true,
                    }],
                    permissions: vec![DriverSettingOption {
                        value: "workspace".to_string(),
                        label: "Workspace".to_string(),
                        description: None,
                        disabled: false,
                    }],
                    default_permissions: Some("workspace".to_string()),
                }),
                CatalogBehavior::Pending => std::future::pending().await,
                CatalogBehavior::ProcessExited => Err(DriverError::ProcessExited(
                    "test provider epoch ended".to_string(),
                )),
            }
        })
    }

    fn start_session<'a>(&'a self, _spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
        Box::pin(async move {
            if matches!(self.catalog, CatalogBehavior::ProcessExited) {
                Err(DriverError::ProcessExited(
                    "test provider epoch ended".to_string(),
                ))
            } else {
                Err(DriverError::Unsupported("test start session"))
            }
        })
    }

    fn resume_session<'a>(&'a self, _spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("test resume session")) })
    }

    fn start_turn<'a>(
        &'a self,
        _session_id: &'a ProviderSessionId,
        _input: TurnInput,
        _options: TurnOptions,
    ) -> DriverFuture<'a, StartedTurn> {
        Box::pin(async {
            let (_sender, events) = AgentEventReceiver::default_channel();
            Ok(StartedTurn {
                turn_id: TurnId::new("turn-test")
                    .map_err(|error| DriverError::Protocol(error.to_string()))?,
                events,
            })
        })
    }

    fn steer_turn<'a>(
        &'a self,
        _session_id: &'a ProviderSessionId,
        _turn_id: &'a TurnId,
        _input: TurnInput,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("test steering")) })
    }

    fn cancel_turn<'a>(
        &'a self,
        _session_id: &'a ProviderSessionId,
        _turn_id: &'a TurnId,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }

    fn compact_session<'a>(&'a self, _session_id: &'a ProviderSessionId) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("test compact")) })
    }

    fn resolve_approval<'a>(
        &'a self,
        _approval_id: &'a str,
        _decision: ApprovalDecision,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }

    fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
}

struct Fixture {
    _directory: tempfile::TempDir,
    store: Arc<BridgeStore>,
    sessions: ProviderSessionManager<FakeDriver>,
    active: ActiveConversation,
    identity: SettingsIdentity,
    snapshot: ConversationSnapshot,
}

impl Fixture {
    fn new(catalog: CatalogBehavior, compact_session: bool) -> Self {
        let directory = tempfile::tempdir().expect("tempdir");
        let store =
            Arc::new(BridgeStore::open(directory.path().join("bridge.sqlite")).expect("store"));
        let installation_id = InstallationId::new("codex").expect("installation");
        let provider_id = ProviderId::new("codex").expect("provider");
        let workspace_id = WorkspaceId::new("workspace").expect("workspace");
        let workspace = directory.path().join("project");
        std::fs::create_dir(&workspace).expect("workspace");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: provider_id.clone(),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        store
            .select_workspace(&installation_id, &workspace_id, &workspace, 1)
            .expect("workspace registration");
        let binding = BindingKey {
            installation_id,
            chat_id: 706,
            workspace_id,
        };
        let snapshot = ConversationSnapshot {
            binding: binding.clone(),
            workspace: workspace.clone(),
        };
        let active = ActiveConversation::new(binding, workspace);
        let sessions = ProviderSessionManager::new(
            Arc::new(FakeDriver {
                catalog,
                compact_session,
            }),
            Arc::clone(&store),
            provider_id,
        );
        Self {
            _directory: directory,
            store,
            sessions,
            active,
            identity: SettingsIdentity {
                owner_user_id: 42,
                owner_dm_chat_id: 43,
                bot_user_id: 84,
                host_installation_id: "host-test".to_string(),
                host_label: "Test Mac".to_string(),
                workspace_picker: None,
                bot_store: SqliteStore::open_in_memory().expect("bot store"),
                reply_thread_default: ReplyThreadDefault {
                    mode: ReplyThreadMode::Auto,
                    source: ReplyThreadDefaultSource::BuiltIn,
                },
            },
            snapshot,
        }
    }

    fn runtime(&self) -> SettingsRuntime<'_, FakeDriver> {
        SettingsRuntime {
            sessions: &self.sessions,
            store: &self.store,
            active: &self.active,
            identity: &self.identity,
            turn_active: false,
        }
    }

    fn revision(&self) -> String {
        let settings = self
            .store
            .chat_settings(&self.snapshot.binding, 2)
            .expect("settings");
        document_revision(&settings, default_reply_policy(settings.binding.chat_id))
    }

    fn invocation(
        &self,
        item_id: &str,
        value: Option<BotSettingsValue>,
        document_revision: String,
    ) -> BotInteractionEvent {
        BotInteractionEvent::ChatSettingsItemInvoked {
            request_id: 1,
            chat_id: InlineId::new(self.snapshot.binding.chat_id),
            actor_user_id: InlineId::new(self.identity.owner_user_id),
            version: SETTINGS_VERSION,
            item_id: item_id.to_string(),
            value,
            document_revision,
        }
    }
}

fn expect_problem(response: BotChatSettingsResponse) -> BotChatSettingsProblem {
    let BotChatSettingsResponse::Problem(problem) = response else {
        panic!("expected settings problem");
    };
    problem
}

#[test]
fn unsupported_settings_answers_are_compatibility_failures() {
    let unsupported = ClientRequestError::Backend(inline_client::BackendError::new(
        ClientErrorCategory::Unsupported,
        "server does not support this method",
    ));
    let internal = ClientRequestError::Backend(inline_client::BackendError::new(
        ClientErrorCategory::Internal,
        "unexpected failure",
    ));

    assert!(is_unsupported_settings_answer(&unsupported));
    assert!(!is_unsupported_settings_answer(&internal));
}

#[test]
fn select_options_preserve_unavailable_values_and_default() {
    let options = [DriverSettingOption {
        value: "high".to_string(),
        label: "High".to_string(),
        description: None,
        disabled: false,
    }];
    let values = select_options(
        Some(options.iter().map(|option| {
            (
                option.value.as_str(),
                option.label.as_str(),
                option.description.as_deref(),
                option.disabled,
            )
        })),
        Some("retired"),
        "Provider default",
    );
    assert_eq!(values[0].value, DEFAULT_VALUE);
    assert!(values.iter().any(|option| {
        option.value == "retired" && option.disabled && option.label == "Unavailable choice"
    }));
}

#[test]
fn model_selection_uses_provider_default_then_first() {
    let model = |value: &str, is_default| DriverModelOption {
        value: value.to_string(),
        label: value.to_string(),
        description: None,
        reasoning: Vec::new(),
        default_reasoning: None,
        is_default,
    };
    let catalog = DriverSettingsCatalog {
        models: vec![model("first", false), model("default", true)],
        permissions: Vec::new(),
        default_permissions: None,
    };
    assert_eq!(
        selected_model(Some(&catalog), None).map(|model| model.value.as_str()),
        Some("default")
    );
    assert_eq!(
        selected_model(Some(&catalog), Some("first")).map(|model| model.value.as_str()),
        Some("first")
    );
}

#[test]
fn revision_is_scoped_to_workspace_and_record_revision() {
    let settings = ChatSettingsRecord {
        binding: BindingKey {
            installation_id: InstallationId::new("codex").expect("installation"),
            chat_id: 42,
            workspace_id: WorkspaceId::new("workspace-a").expect("workspace"),
        },
        model: None,
        reasoning: None,
        permissions: None,
        verbose: false,
        revision: 7,
        updated_at: 1,
    };
    assert_eq!(
        document_revision(&settings, default_reply_policy(42)),
        "settings-v2-workspace-a-7-42-auto-0"
    );
}

fn default_reply_policy(chat_id: i64) -> EffectiveReplyThreadPolicy {
    EffectiveReplyThreadPolicy {
        scope: ReplyThreadScope {
            current_chat_id: chat_id,
            scope_chat_id: chat_id,
            existing_reply_thread: false,
        },
        mode: ReplyThreadMode::Auto,
        source: ReplyThreadPolicySource::BuiltInDefault,
        override_revision: None,
    }
}

#[test]
fn command_choices_page_six_options_with_navigation_and_cancel() {
    let options = (0..13)
        .map(|index| SettingsCommandChoice {
            value: format!("value-{index}"),
            label: format!("Choice {index}"),
        })
        .collect::<Vec<_>>();

    let first = command_choice_actions("token", 0, &options).expect("first page");
    assert_eq!(command_choice_page_count(options.len()), 3);
    let first_buttons = first
        .rows
        .iter()
        .flat_map(|row| row.actions.iter())
        .collect::<Vec<_>>();
    assert_eq!(
        first_buttons
            .iter()
            .filter(|button| button.action_id.starts_with("bridge_setting_choice_"))
            .count(),
        6
    );
    assert!(first_buttons.iter().any(|button| button.text == "More"));
    assert!(!first_buttons.iter().any(|button| button.text == "Back"));
    assert!(first_buttons.iter().any(|button| button.text == "Cancel"));

    let last = command_choice_actions("token", 2, &options).expect("last page");
    let last_buttons = last
        .rows
        .iter()
        .flat_map(|row| row.actions.iter())
        .collect::<Vec<_>>();
    assert_eq!(
        last_buttons
            .iter()
            .filter(|button| button.action_id.starts_with("bridge_setting_choice_"))
            .count(),
        1
    );
    assert!(last_buttons.iter().any(|button| button.text == "Back"));
    assert!(!last_buttons.iter().any(|button| button.text == "More"));
}

#[test]
fn command_choice_callbacks_only_embed_an_opaque_token_and_action() {
    let options = vec![SettingsCommandChoice {
        value: "gpt-test".to_string(),
        label: "GPT Test".to_string(),
    }];
    let actions = command_choice_actions("opaque-token", 0, &options).expect("actions");
    let MessageActionKind::Callback { data } = &actions.rows[0].actions[0].kind else {
        panic!("expected callback");
    };
    let callback: SettingsCommandChoiceCallback = serde_json::from_slice(data).expect("callback");
    assert_eq!(callback.token, "opaque-token");
    assert!(matches!(
        callback.action,
        SettingsCommandChoiceCallbackAction::Select { ref value } if value == "gpt-test"
    ));
    let encoded = String::from_utf8(data.clone()).expect("utf8");
    assert!(!encoded.contains("installation_id"));
    assert!(!encoded.contains("workspace_id"));
    assert!(!encoded.contains("document_revision"));
}

#[tokio::test]
async fn stale_toolbar_revision_returns_the_fresh_document() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    let response = resolve_settings_interaction(
        &fixture.invocation(
            ITEM_VERBOSE,
            Some(BotSettingsValue::Bool(true)),
            "settings-v1-workspace-0".to_string(),
        ),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    let problem = expect_problem(response.response);
    assert_eq!(problem.code, BotChatSettingsProblemCode::Stale);
    assert_eq!(
        problem.current_document.expect("fresh document").revision,
        fixture.revision()
    );
}

#[tokio::test]
async fn invalid_toolbar_option_is_rejected_without_mutating_settings() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    let revision = fixture.revision();
    let response = resolve_settings_interaction(
        &fixture.invocation(
            ITEM_MODEL,
            Some(BotSettingsValue::String("retired-model".to_string())),
            revision.clone(),
        ),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    let problem = expect_problem(response.response);
    assert_eq!(problem.code, BotChatSettingsProblemCode::InvalidValue);
    assert_eq!(fixture.revision(), revision);
}

#[tokio::test]
async fn unsupported_compaction_returns_truthful_problem() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    let response = resolve_settings_interaction(
        &fixture.invocation(ITEM_COMPACT, None, fixture.revision()),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    let problem = expect_problem(response.response);
    assert_eq!(problem.code, BotChatSettingsProblemCode::InvalidValue);
    assert_eq!(
        problem.message,
        BridgeNotice::SessionCompactionUnsupported.message()
    );
}

#[tokio::test]
async fn catalog_timeout_keeps_safe_controls_available_and_disables_provider_options() {
    let fixture = Fixture::new(CatalogBehavior::Pending, false);
    let request = BotInteractionEvent::ChatSettingsRequested {
        request_id: 1,
        chat_id: InlineId::new(fixture.snapshot.binding.chat_id),
        actor_user_id: InlineId::new(fixture.identity.owner_user_id),
        version: SETTINGS_VERSION,
    };
    let response = resolve_settings_interaction_with_deadline(
        &request,
        &fixture.runtime(),
        fixture.snapshot.clone(),
        Duration::from_millis(1),
    )
    .await;
    let BotChatSettingsResponse::Document(document) = response.response else {
        panic!("expected degraded settings document");
    };
    let model = document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.id == ITEM_MODEL)
        .expect("model item");
    let verbose = document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.id == ITEM_VERBOSE)
        .expect("verbose item");
    assert!(model.disabled);
    assert_eq!(
        model.disabled_reason.as_deref(),
        Some("Provider options are temporarily unavailable.")
    );
    assert!(!verbose.disabled);
}

#[tokio::test]
async fn unset_permission_selection_names_the_effective_default() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    let request = BotInteractionEvent::ChatSettingsRequested {
        request_id: 1,
        chat_id: InlineId::new(fixture.snapshot.binding.chat_id),
        actor_user_id: InlineId::new(fixture.identity.owner_user_id),
        version: SETTINGS_VERSION,
    };
    let response =
        resolve_settings_interaction(&request, &fixture.runtime(), fixture.snapshot.clone()).await;
    let BotChatSettingsResponse::Document(document) = response.response else {
        panic!("expected settings document");
    };
    let permissions = document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.id == ITEM_PERMISSIONS)
        .expect("permissions item");
    let BotChatSettingsControl::Select { value, options } = &permissions.control else {
        panic!("expected permissions select");
    };
    assert_eq!(value, DEFAULT_VALUE);
    assert_eq!(options[0].value, DEFAULT_VALUE);
    assert_eq!(options[0].label, "Workspace (default)");
    assert!(
        options
            .iter()
            .any(|option| { option.value == "workspace" && option.label == "Workspace" })
    );
}

#[test]
fn permission_status_and_reset_copy_name_the_effective_default() {
    let catalog = DriverSettingsCatalog {
        models: Vec::new(),
        permissions: vec![DriverSettingOption {
            value: "bypassPermissions".to_string(),
            label: "Bypass Permissions".to_string(),
            description: None,
            disabled: false,
        }],
        default_permissions: Some("bypassPermissions".to_string()),
    };
    assert_eq!(
        permission_selection_label(None, Some(&catalog)),
        "Bypass Permissions (default)"
    );
    assert_eq!(
        permission_selection_label(Some("bypassPermissions"), Some(&catalog)),
        "Bypass Permissions"
    );
}

#[tokio::test]
async fn slash_settings_catalog_epoch_loss_is_fatal() {
    let fixture = Fixture::new(CatalogBehavior::ProcessExited, false);
    let result = resolve_settings_command(&fixture.runtime(), "model", "").await;

    assert!(result.provider_epoch_ended);
    assert_eq!(
        result.message,
        "Provider options are temporarily unavailable."
    );
    assert!(result.failure.is_some());
}

#[tokio::test]
async fn toolbar_settings_catalog_epoch_loss_is_fatal_after_a_truthful_response() {
    let fixture = Fixture::new(CatalogBehavior::ProcessExited, false);
    let request = BotInteractionEvent::ChatSettingsRequested {
        request_id: 1,
        chat_id: InlineId::new(fixture.snapshot.binding.chat_id),
        actor_user_id: InlineId::new(fixture.identity.owner_user_id),
        version: SETTINGS_VERSION,
    };
    let resolution = resolve_settings_interaction_with_deadline(
        &request,
        &fixture.runtime(),
        fixture.snapshot.clone(),
        Duration::from_millis(10),
    )
    .await;

    assert!(resolution.provider_epoch_ended);
    let problem = expect_problem(resolution.response);
    assert_eq!(problem.code, BotChatSettingsProblemCode::Unavailable);
    assert_eq!(problem.message, BridgeNotice::AgentConnectionLost.message());
}

#[tokio::test]
async fn toolbar_session_mutation_epoch_loss_is_fatal() {
    let fixture = Fixture::new(CatalogBehavior::ProcessExited, false);
    let current = fixture
        .store
        .chat_settings(&fixture.snapshot.binding, 2)
        .expect("settings");
    let failure = apply_invocation(
        &fixture.runtime(),
        &fixture.snapshot,
        current,
        None,
        ITEM_NEW,
        None,
    )
    .await
    .expect_err("session mutation must fail");

    assert!(failure.provider_epoch_ended);
    let problem = expect_problem(failure.response);
    assert_eq!(problem.code, BotChatSettingsProblemCode::Failed);
}

#[test]
fn reconnect_settings_response_is_owner_scoped_and_actionable() {
    let restarting =
        "Agent settings are temporarily unavailable while the local provider restarts.";
    let owner = expect_problem(unavailable_settings_response(42, 42, restarting));
    assert_eq!(owner.code, BotChatSettingsProblemCode::Unavailable);
    assert!(owner.message.contains("provider restarts"));

    let outsider = expect_problem(unavailable_settings_response(99, 42, restarting));
    assert_eq!(outsider.code, BotChatSettingsProblemCode::Unavailable);
    assert!(outsider.message.contains("Only the bot owner"));

    let missing_workspace = expect_problem(unavailable_settings_response(
        42,
        42,
        BridgeNotice::MissingWorkspace.message(),
    ));
    assert_eq!(
        missing_workspace.message,
        BridgeNotice::MissingWorkspace.message()
    );
    let outsider = expect_problem(unavailable_settings_response(
        99,
        42,
        BridgeNotice::MissingWorkspace.message(),
    ));
    assert!(!outsider.message.contains("project folder"));
}
