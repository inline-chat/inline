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
                codex_projects_path: None,
                codex_project_rpc: None,
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

    fn route(&self) -> InboundRoute {
        let (_deferred_tx, _deferred_rx) = tokio::sync::mpsc::channel(1);
        InboundRoute {
            store: Arc::clone(&self.store),
            installation_id: self.snapshot.binding.installation_id.clone(),
            provider_id: ProviderId::new("codex").expect("provider"),
            policy: Arc::new(RwLock::new(OperatorPolicy::owner_only(
                self.identity.owner_user_id,
            ))),
            owner_user_id: self.identity.owner_user_id,
            host_label: self.identity.host_label.clone(),
            owner_dm_chat_id: self.snapshot.binding.chat_id,
            bot_user_id: self.identity.bot_user_id,
            bot_username: "test_codex_bot".to_string(),
            bot_store: self.identity.bot_store.clone(),
            attachment_cache_dir: self._directory.path().join("attachments"),
            owner_control: None,
            accept_messages_after: 0,
            deferred_inbound_tx: _deferred_tx,
            pending_voice_messages: Arc::new(std::sync::Mutex::new(HashSet::new())),
            claude_history: None,
            control_lane: Arc::new(tokio::sync::Semaphore::new(1)),
            control_epoch: ControlTaskEpoch::new(),
            bot_agent_resolver: BotAgentResolver::disabled(),
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

#[test]
fn provider_restart_settings_keep_project_selection_local_and_usable() {
    let fixture = Fixture::new(CatalogBehavior::ProcessExited, false);
    fixture
        .store
        .bind_chat_workspace(
            &fixture.snapshot.binding.installation_id,
            fixture.snapshot.binding.chat_id,
            &fixture.snapshot.binding.workspace_id,
            1,
        )
        .expect("initial chat workspace");
    let route = fixture.route();
    let second_workspace_id = WorkspaceId::new("workspace-two").expect("workspace id");
    let second_workspace = fixture._directory.path().join("project-two");
    std::fs::create_dir(&second_workspace).expect("second workspace");
    fixture
        .store
        .select_workspace(
            &fixture.snapshot.binding.installation_id,
            &second_workspace_id,
            &second_workspace,
            2,
        )
        .expect("second workspace registration");

    let first = provider_unavailable_project_document(&route, fixture.snapshot.binding.chat_id)
        .expect("restart document");
    assert_eq!(first.sections.len(), 2);
    let folder = &first.sections[0].items[0];
    assert_eq!(folder.id, ITEM_FOLDER);
    let BotChatSettingsControl::Folder(folder) = &folder.control else {
        panic!("project row must remain a folder selector");
    };
    assert!(!folder.allows_local_picker);
    assert!(
        folder
            .recent_folders
            .iter()
            .any(|option| option.value == second_workspace_id.as_str())
    );

    let response = resolve_provider_unavailable_project_settings(
        &BotInteractionEvent::ChatSettingsItemInvoked {
            request_id: 1,
            chat_id: InlineId::new(fixture.snapshot.binding.chat_id),
            actor_user_id: InlineId::new(fixture.identity.owner_user_id),
            version: SETTINGS_VERSION,
            item_id: ITEM_FOLDER.to_string(),
            value: Some(BotSettingsValue::String(second_workspace_id.to_string())),
            document_revision: first.revision,
        },
        &route,
        fixture.snapshot.binding.chat_id,
    );
    let BotChatSettingsResponse::Document(document) = response else {
        panic!("selection should return the refreshed reduced document");
    };
    let BotChatSettingsControl::Folder(folder) = &document.sections[0].items[0].control else {
        panic!("refreshed project row must remain a folder selector");
    };
    assert_eq!(folder.value, second_workspace_id.as_str());
    assert_eq!(
        fixture
            .store
            .chat_workspace(
                &fixture.snapshot.binding.installation_id,
                fixture.snapshot.binding.chat_id,
            )
            .expect("chat workspace")
            .expect("bound workspace")
            .workspace_id,
        second_workspace_id
    );
}

#[tokio::test]
async fn project_browser_pages_all_projects_and_selects_beyond_quick_choices() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    let installation = &fixture.snapshot.binding.installation_id;
    for index in 0..120 {
        let path = fixture._directory.path().join(format!("saved-{index:03}"));
        std::fs::create_dir(&path).unwrap();
        fixture
            .store
            .discover_workspace(
                installation,
                &WorkspaceId::new(format!("saved-{index:03}")).unwrap(),
                &path,
            )
            .unwrap();
    }
    let settings = fixture
        .store
        .chat_settings(&fixture.snapshot.binding, 2)
        .unwrap();
    let base = build_settings_document(&fixture.runtime(), &fixture.snapshot, &settings, None)
        .await
        .unwrap();
    let items = base
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .collect::<Vec<_>>();
    let BotChatSettingsControl::Folder(folder) = &items
        .iter()
        .find(|item| item.id == ITEM_FOLDER)
        .unwrap()
        .control
    else {
        panic!("folder")
    };
    assert_eq!(folder.recent_folders.len(), 8);
    assert!(items.iter().any(|item| item.id == ITEM_PROJECTS));
    let mut values = HashSet::new();
    for page in 0..2 {
        let response = resolve_settings_interaction(
            &fixture.invocation(
                &format!("{PROJECT_PAGE_PREFIX}{page}"),
                None,
                base.revision.clone(),
            ),
            &fixture.runtime(),
            fixture.snapshot.clone(),
        )
        .await;
        let BotChatSettingsResponse::Document(document) = response.response else {
            panic!("project page")
        };
        let BotChatSettingsControl::Select { value, options } =
            &document.sections[0].items[0].control
        else {
            panic!("project select")
        };
        assert!(options.len() <= 100);
        assert!(options.iter().any(|option| option.value == *value));
        values.extend(options.iter().map(|option| option.value.clone()));
    }
    assert_eq!(values.len(), 121, "no clipping at eight or 100 projects");
    assert!(
        project_settings_document(&fixture.runtime(), &fixture.snapshot, &base, usize::MAX)
            .is_err()
    );
    let invalid = resolve_settings_interaction(
        &fixture.invocation(
            &format!("{PROJECT_PAGE_PREFIX}invalid"),
            None,
            base.revision.clone(),
        ),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    assert!(matches!(
        invalid.response,
        BotChatSettingsResponse::Problem(_)
    ));
    let busy = SettingsRuntime {
        turn_active: true,
        ..fixture.runtime()
    };
    let selection = Some(BotSettingsValue::String("saved-119".to_string()));
    let rejected = resolve_settings_interaction(
        &fixture.invocation(ITEM_PROJECT, selection.clone(), base.revision.clone()),
        &busy,
        fixture.snapshot.clone(),
    )
    .await;
    assert!(matches!(
        rejected.response,
        BotChatSettingsResponse::Problem(_)
    ));
    let selected = resolve_settings_interaction(
        &fixture.invocation(ITEM_PROJECT, selection, base.revision.clone()),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    assert!(matches!(
        selected.response,
        BotChatSettingsResponse::Document(_)
    ));
    assert_eq!(
        fixture.active.snapshot().binding.workspace_id.as_str(),
        "saved-119"
    );
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
async fn linked_compaction_requires_history_sync_without_acquiring_a_writer() {
    let fixture = Fixture::new(CatalogBehavior::Ready, true);
    let binding = &fixture.snapshot.binding;
    let session = inline_agent_bridge::ProviderSessionRef::new(
        inline_agent_bridge::ProviderInstanceRef::new(
            binding.installation_id.clone(),
            ProviderId::new("codex").unwrap(),
        )
        .unwrap(),
        ProviderSessionId::new("linked-session").unwrap(),
    )
    .unwrap();
    fixture
        .sessions
        .bind_session_thread(
            &inline_agent_bridge::SessionThreadBinding::new(
                session,
                binding.workspace_id.clone(),
                43,
                binding.chat_id,
            )
            .unwrap(),
            1,
        )
        .await
        .unwrap();
    let response = resolve_settings_interaction(
        &fixture.invocation(ITEM_COMPACT, None, fixture.revision()),
        &fixture.runtime(),
        fixture.snapshot.clone(),
    )
    .await;
    assert!(
        expect_problem(response.response)
            .message
            .contains("/resume")
    );
    assert!(!fixture.sessions.session_is_active(binding).await);
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

#[tokio::test]
async fn missing_selected_workspace_remains_in_recovery_document_as_disabled() {
    let fixture = Fixture::new(CatalogBehavior::Ready, false);
    std::fs::rename(
        &fixture.snapshot.workspace,
        fixture._directory.path().join("moved-project"),
    )
    .expect("make the selected root unavailable");
    fixture
        .store
        .mark_workspace_unavailable(
            &fixture.snapshot.binding.installation_id,
            &fixture.snapshot.binding.workspace_id,
            3,
        )
        .expect("mark unavailable");
    let recents_root = tempfile::tempdir().expect("recent workspaces root");
    for index in 0..MAX_RECENT_WORKSPACES {
        let path = recents_root.path().join(format!("recent-{index}"));
        std::fs::create_dir(&path).expect("create recent workspace");
        fixture
            .store
            .select_workspace(
                &fixture.snapshot.binding.installation_id,
                &WorkspaceId::new(format!("recent-{index}")).expect("workspace id"),
                &path,
                10 + index as i64,
            )
            .expect("select recent workspace");
    }
    let settings = fixture
        .store
        .chat_settings(&fixture.snapshot.binding, 4)
        .expect("settings");

    let document = build_settings_document(&fixture.runtime(), &fixture.snapshot, &settings, None)
        .await
        .expect("recovery document");

    let folder = document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.id == ITEM_FOLDER)
        .expect("folder item");
    let BotChatSettingsControl::Folder(folder) = &folder.control else {
        panic!("expected folder control");
    };
    assert!(folder.recent_folders.len() <= MAX_RECENT_WORKSPACES);
    let selected = folder
        .recent_folders
        .iter()
        .find(|choice| choice.value == folder.value)
        .expect("selected recovery option");
    assert!(selected.disabled);
}

#[tokio::test]
async fn invalid_saved_catalog_does_not_disable_folder_recovery() {
    let mut fixture = Fixture::new(CatalogBehavior::Ready, false);
    let state = fixture._directory.path().join("invalid-project-state.json");
    std::fs::write(&state, b"{").unwrap();
    fixture.identity.codex_projects_path = Some(state);
    let settings = fixture
        .store
        .chat_settings(&fixture.snapshot.binding, 2)
        .unwrap();
    let document = build_settings_document(&fixture.runtime(), &fixture.snapshot, &settings, None)
        .await
        .unwrap();
    let section = document
        .sections
        .iter()
        .find(|section| section.id == "project")
        .unwrap();
    assert!(
        section
            .description
            .as_deref()
            .unwrap()
            .contains("could not be refreshed")
    );
    assert!(
        !section
            .items
            .iter()
            .find(|item| item.id == ITEM_FOLDER)
            .unwrap()
            .disabled
    );
    assert!(
        project_settings_document(&fixture.runtime(), &fixture.snapshot, &document, 0).is_err()
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
async fn project_picker_remains_local_when_provider_catalog_is_down() {
    let fixture = Fixture::new(CatalogBehavior::ProcessExited, false);
    let result = resolve_settings_command(&fixture.runtime(), "folder", "").await;

    assert!(!result.provider_epoch_ended);
    assert!(result.failure.is_none());
    assert!(result.message.contains("Current project: project"));
    assert!(result.choices.is_some());
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
