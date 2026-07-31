use super::*;

pub async fn run_codex_dev(
    config: &Config,
    owner_token: String,
    folder: PathBuf,
) -> Result<(), Box<dyn std::error::Error>> {
    let workspace = canonical_workspace(&folder)?;
    let provider = probe_provider(PROVIDER_ID).map_err(io::Error::other)?;
    let provisioned = provision_dev_bot(config, &owner_token, &provider, &workspace, None).await?;
    run_provider_installation(
        config,
        provisioned.installation,
        ProviderRuntimeContext {
            paths: provisioned.paths,
            account: provisioned.account,
            credentials: provisioned.credentials,
            background_service: false,
            external_shutdown: None,
            shared_owner_control: None,
            owner_control_managed: false,
            shared_manifest_write: None,
            shared_turn_capacity: Arc::new(tokio::sync::Semaphore::new(
                MAX_ACCOUNT_CONCURRENT_TURNS,
            )),
            shared_probe_capacity: Arc::new(tokio::sync::Semaphore::new(1)),
            shared_provider_readiness: None,
            workspace_picker: None,
        },
    )
    .await
}

pub struct DebugSettingsRequest {
    pub bot_user_id: i64,
    pub chat_id: i64,
    pub item_id: Option<String>,
    pub document_revision: Option<String>,
    pub string_value: Option<String>,
    pub bool_value: Option<bool>,
}

pub async fn debug_request_settings(
    config: &Config,
    owner_token: &str,
    request: DebugSettingsRequest,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut owner = connect_realtime(&config.realtime_url, owner_token).await?;
    let peer_id = Some(proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id: request.chat_id,
        })),
    });
    let mut result = match request.item_id {
        Some(item_id) => {
            let value = request
                .string_value
                .map(proto::bot_chat_settings_value::Value::StringValue)
                .or_else(|| {
                    request
                        .bool_value
                        .map(proto::bot_chat_settings_value::Value::BoolValue)
                })
                .map(|value| proto::BotChatSettingsValue { value: Some(value) });
            let response = owner
                .call(proto::InvokeBotChatSettingsItemInput {
                    peer_id,
                    bot_user_id: request.bot_user_id,
                    version: 1,
                    item_id,
                    value,
                    document_revision: request.document_revision.ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "settings invocation requires a document revision",
                        )
                    })?,
                })
                .await?;
            serde_json::to_value(response)?
        }
        None => serde_json::to_value(
            owner
                .call(proto::RequestBotChatSettingsInput {
                    peer_id,
                    bot_user_id: request.bot_user_id,
                    version: 1,
                })
                .await?,
        )?,
    };
    redact_debug_settings_secrets(&mut result);
    output::print_json(&result, json_format)?;
    Ok(())
}

pub(super) fn redact_debug_settings_secrets(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(fields) => {
            for (key, value) in fields {
                if matches!(
                    key.as_str(),
                    "localPickerCapability" | "local_picker_capability"
                ) {
                    *value = serde_json::Value::String("[redacted]".to_string());
                } else {
                    redact_debug_settings_secrets(value);
                }
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                redact_debug_settings_secrets(value);
            }
        }
        _ => {}
    }
}

pub async fn debug_probe_workspace_picker(
    config: &Config,
    owner_token: &str,
    bot_user_id: i64,
    chat_id: i64,
    folder: Option<PathBuf>,
) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (config, owner_token, bot_user_id, chat_id, folder);
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "the host-local folder picker is available only on macOS",
        )
        .into());
    }

    #[cfg(target_os = "macos")]
    {
        let mut owner = connect_realtime(&config.realtime_url, owner_token).await?;
        let result = owner
            .call(proto::RequestBotChatSettingsInput {
                peer_id: Some(proto::InputPeer {
                    r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
                        chat_id,
                    })),
                }),
                bot_user_id,
                version: 1,
            })
            .await?;
        let response = result.response.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "agent settings response was empty",
            )
        })?;
        let document = match response.result {
            Some(proto::bot_chat_settings_response::Result::Document(document)) => document,
            Some(proto::bot_chat_settings_response::Result::Problem(problem)) => {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    safe_diagnostic(&problem.message),
                )
                .into());
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "agent settings response had no result",
                )
                .into());
            }
        };
        let picker = document
            .sections
            .into_iter()
            .flat_map(|section| section.items)
            .find_map(|item| match item.control {
                Some(proto::bot_chat_settings_item::Control::Folder(folder))
                    if folder.allows_local_picker =>
                {
                    Some(folder)
                }
                _ => None,
            })
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "agent settings did not advertise a host-local picker",
                )
            })?;
        let port = picker
            .local_picker_port
            .and_then(|port| u16::try_from(port).ok())
            .filter(|port| *port >= 1024)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "agent settings advertised an invalid picker port",
                )
            })?;
        let capability = picker.local_picker_capability.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "agent settings omitted the picker capability",
            )
        })?;
        let endpoint = WorkspacePickerEndpoint { port, capability };
        match call_workspace_picker(&endpoint, &picker.host_installation_id, bot_user_id, folder)
            .await?
        {
            Some(workspace_id) => {
                println!("Host-local folder registration succeeded: {workspace_id}");
            }
            None => println!("Host-local folder picker is reachable."),
        }
        Ok(())
    }
}

pub async fn debug_observe_typing(
    config: &Config,
    owner_token: &str,
    bot_user_id: i64,
    timeout: Duration,
) -> Result<(), Box<dyn std::error::Error>> {
    if bot_user_id <= 0 {
        return Err(
            io::Error::new(io::ErrorKind::InvalidInput, "bot user id must be positive").into(),
        );
    }
    let session = inline_sdk::RealtimeClient::builder(&config.realtime_url, owner_token)
        .identity(crate::identity::client_identity())
        .connect_session()
        .await?;
    let mut events = session.subscribe();
    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);
    let mut typing_updates = 0_usize;
    loop {
        tokio::select! {
            event = events.recv() => {
                let inline_sdk::RealtimeEvent::Updates(updates) = event? else {
                    continue;
                };
                for update in updates {
                    let Some(proto::update::Update::UpdateComposeAction(update)) = update.update else {
                        continue;
                    };
                    if update.user_id != bot_user_id {
                        continue;
                    }
                    if update.action
                        == proto::update_compose_action::ComposeAction::Typing as i32
                    {
                        typing_updates = typing_updates.saturating_add(1);
                    } else if typing_updates > 0 {
                        println!(
                            "Observed {typing_updates} typing update(s) and a terminal clear for bot {bot_user_id}."
                        );
                        return Ok(());
                    }
                }
            }
            _ = &mut deadline => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!(
                        "typing observation timed out after {} update(s) for bot {bot_user_id}",
                        typing_updates
                    ),
                ).into());
            }
        }
    }
}
