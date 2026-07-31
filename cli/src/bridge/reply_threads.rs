//! Inline-native reply-thread policy resolution.

use std::sync::LazyLock;

use regex::Regex;

#[cfg(test)]
use inline_client::DialogRecord;

use super::*;

// Inline message IDs are monotonic within a chat, so the latest ID is the
// cheapest no-extra-RPC maturity hint. Keep the threshold tunable and tested.
pub(super) const AUTO_REPLY_THREAD_MESSAGE_THRESHOLD: i64 = 15;

static REPLY_THREAD_NEGATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)
        \b(?:do\s+not|don't|dont|please\s+don't|please\s+dont|no\s+need\s+to)\s+
        (?:create|start|open|make|use|move|take|reply|respond|answer|send|thread)\b[^.!?\n]*\bthread\b
        |
        \b(?:reply|respond|answer|keep)\s+(?:here|in\s+the\s+main\s+chat|in\s+main\s+chat|
        in\s+the\s+parent\s+chat|in\s+parent\s+chat)\b",
    )
    .expect("reply-thread negation regex")
});

static REPLY_THREAD_INTENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)
        \b(?:reply|respond|answer|send)\s+(?:in|inside|into|to)\s+(?:an?\s+)?
        (?:(?:new|child|inline|reply)\s+){0,2}thread\b
        |
        \b(?:create|start|open|make|use)\s+(?:an?\s+)?(?:(?:new|child|reply)\s+)?thread\b
        |
        \bkeep\s+(?:(?:this|it|the\s+answer|the\s+reply|the\s+response)\s+)?
        (?:in|inside|into)\s+(?:an?\s+)?(?:(?:new|child|reply)\s+)?thread\b
        |
        \b(?:move|take)\s+(?:(?:this|it|(?:this|the)\s+answer|(?:this|the)\s+reply|(?:this|the)\s+response)\s+)?
        (?:to|into)\s+(?:an?\s+)?(?:(?:new|child|reply)\s+)?thread\b
        |
        \bthread\s+(?:this|the\s+answer|the\s+reply|the\s+response)\b
        |
        \b(?:threaded\s+(?:reply|response)|(?:reply|respond|answer)\s+threaded)\b",
    )
    .expect("reply-thread intent regex")
});

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ReplyThreadScope {
    pub current_chat_id: i64,
    pub scope_chat_id: i64,
    pub existing_reply_thread: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReplyThreadPolicySource {
    ChatOverride,
    ProviderDefault,
    GlobalDefault,
    BuiltInDefault,
}

impl ReplyThreadPolicySource {
    pub(super) const fn label(self) -> &'static str {
        match self {
            Self::ChatOverride => "chat override",
            Self::ProviderDefault => "provider default",
            Self::GlobalDefault => "global default",
            Self::BuiltInDefault => "built-in default",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct EffectiveReplyThreadPolicy {
    pub scope: ReplyThreadScope,
    pub mode: ReplyThreadMode,
    pub source: ReplyThreadPolicySource,
    pub override_revision: Option<i64>,
}

pub(super) async fn resolve_reply_thread_scope(
    bot_store: &SqliteStore,
    chat_id: i64,
) -> Result<ReplyThreadScope, Box<dyn std::error::Error>> {
    let dialog = bot_store.dialog(InlineId::new(chat_id)).await?;
    let anchored_parent = dialog.as_ref().and_then(|dialog| {
        dialog
            .parent_message_id
            .and(dialog.parent_chat_id)
            .map(InlineId::get)
    });
    Ok(ReplyThreadScope {
        current_chat_id: chat_id,
        scope_chat_id: anchored_parent.unwrap_or(chat_id),
        existing_reply_thread: anchored_parent.is_some(),
    })
}

pub(super) async fn resolve_reply_thread_policy(
    store: &BridgeStore,
    installation_id: &InstallationId,
    bot_store: &SqliteStore,
    default: ReplyThreadDefault,
    chat_id: i64,
) -> Result<EffectiveReplyThreadPolicy, Box<dyn std::error::Error>> {
    let scope = resolve_reply_thread_scope(bot_store, chat_id).await?;
    if let Some(record) = store.reply_thread_override(installation_id, scope.scope_chat_id)? {
        return Ok(EffectiveReplyThreadPolicy {
            scope,
            mode: record.mode,
            source: ReplyThreadPolicySource::ChatOverride,
            override_revision: Some(record.revision),
        });
    }
    let source = match default.source {
        ReplyThreadDefaultSource::Provider => ReplyThreadPolicySource::ProviderDefault,
        ReplyThreadDefaultSource::Global => ReplyThreadPolicySource::GlobalDefault,
        ReplyThreadDefaultSource::BuiltIn => ReplyThreadPolicySource::BuiltInDefault,
    };
    Ok(EffectiveReplyThreadPolicy {
        scope,
        mode: default.mode,
        source,
        override_revision: None,
    })
}

pub(super) fn has_explicit_reply_thread_intent(text: &str) -> bool {
    let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
    !normalized.is_empty()
        && !REPLY_THREAD_NEGATION.is_match(&normalized)
        && REPLY_THREAD_INTENT.is_match(&normalized)
}

fn has_explicit_reply_thread_negation(text: &str) -> bool {
    let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
    !normalized.is_empty() && REPLY_THREAD_NEGATION.is_match(&normalized)
}

pub(super) fn should_create_reply_thread(
    mode: ReplyThreadMode,
    source_is_direct_message: bool,
    source_last_message_id: Option<i64>,
    text: &str,
) -> bool {
    match mode {
        ReplyThreadMode::Auto => {
            !source_is_direct_message
                && !has_explicit_reply_thread_negation(text)
                && (source_last_message_id
                    .is_some_and(|message_id| message_id > AUTO_REPLY_THREAD_MESSAGE_THRESHOLD)
                    || has_explicit_reply_thread_intent(text))
        }
        ReplyThreadMode::On => true,
        ReplyThreadMode::Off => false,
    }
}

pub(super) async fn prepare_turn_delivery(
    bot: &InlineClient,
    store: &BridgeStore,
    identity: &SettingsIdentity,
    source_binding: &BindingKey,
    record: &InboundRecord,
    instruction: &str,
) -> Result<BindingKey, Box<dyn std::error::Error>> {
    let policy = resolve_reply_thread_policy(
        store,
        &source_binding.installation_id,
        &identity.bot_store,
        identity.reply_thread_default,
        source_binding.chat_id,
    )
    .await?;
    let source_dialog = identity
        .bot_store
        .dialog(InlineId::new(source_binding.chat_id))
        .await?;
    let source_is_direct_message = source_binding.chat_id == identity.owner_dm_chat_id
        || source_dialog
            .as_ref()
            .is_some_and(|dialog| dialog.peer_user_id.is_some());
    let source_last_message_id = source_dialog.as_ref().map(|dialog| {
        dialog
            .last_message_id
            .map(InlineId::get)
            .unwrap_or_default()
            .max(record.message_id)
    });
    let delivery_chat_id = if policy.scope.existing_reply_thread
        || !should_create_reply_thread(
            policy.mode,
            source_is_direct_message,
            source_last_message_id,
            instruction,
        ) {
        source_binding.chat_id
    } else {
        bot.create_reply_thread(CreateReplyThreadRequest {
            parent_chat_id: InlineId::new(source_binding.chat_id),
            parent_message_id: Some(InlineId::new(record.message_id)),
            title: None,
            description: None,
            emoji: None,
            participants: Vec::new(),
        })
        .await?
        .chat_id
        .get()
    };
    if delivery_chat_id == source_binding.chat_id {
        if !store.set_inbound_delivery_chat(&record.event_id, delivery_chat_id)? {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "turn delivery lane could not be recorded before provider start",
            )
            .into());
        }
        return Ok(source_binding.clone());
    }
    let target = BindingKey {
        installation_id: source_binding.installation_id.clone(),
        chat_id: delivery_chat_id,
        workspace_id: source_binding.workspace_id.clone(),
    };
    store.bind_chat_workspace(
        &target.installation_id,
        target.chat_id,
        &target.workspace_id,
        now_seconds(),
    )?;
    let _ = store.chat_settings(source_binding, now_seconds())?;
    let _ = store.inherit_chat_settings(source_binding, &target, now_seconds())?;
    if !store.set_inbound_delivery_chat(&record.event_id, delivery_chat_id)? {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "turn delivery lane could not be recorded before provider start",
        )
        .into());
    }
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_intent_is_bounded_and_negation_wins() {
        for text in [
            "Reply in a thread, please",
            "Reply in an Inline reply thread, please",
            "Move this response into a reply thread",
            "Thread this",
            "Please answer threaded",
        ] {
            assert!(has_explicit_reply_thread_intent(text), "{text}");
        }
        for text in [
            "Investigate the thread safety issue",
            "Reply here",
            "Do not create a thread; answer here",
            "Please don't move this response into a thread",
        ] {
            assert!(!has_explicit_reply_thread_intent(text), "{text}");
        }
    }

    #[test]
    fn contextual_auto_keeps_dms_and_fresh_chats_flat() {
        assert!(!should_create_reply_thread(
            ReplyThreadMode::Auto,
            true,
            Some(100),
            "Reply in a thread",
        ));
        assert!(!should_create_reply_thread(
            ReplyThreadMode::Auto,
            false,
            Some(AUTO_REPLY_THREAD_MESSAGE_THRESHOLD),
            "Answer normally",
        ));
        assert!(!should_create_reply_thread(
            ReplyThreadMode::Auto,
            false,
            None,
            "Answer normally",
        ));
        assert!(should_create_reply_thread(
            ReplyThreadMode::On,
            true,
            Some(1),
            "Answer normally",
        ));
    }

    #[test]
    fn contextual_auto_threads_mature_chats_and_respects_explicit_negation() {
        assert!(should_create_reply_thread(
            ReplyThreadMode::Auto,
            false,
            Some(AUTO_REPLY_THREAD_MESSAGE_THRESHOLD + 1),
            "Please investigate",
        ));
        assert!(!should_create_reply_thread(
            ReplyThreadMode::Auto,
            false,
            Some(AUTO_REPLY_THREAD_MESSAGE_THRESHOLD + 1),
            "Reply here in the main chat",
        ));
        assert!(should_create_reply_thread(
            ReplyThreadMode::Auto,
            false,
            Some(2),
            "Reply in an Inline reply thread",
        ));
    }

    #[tokio::test]
    async fn anchored_children_use_parent_scope_but_unanchored_children_do_not() {
        let bot_store = SqliteStore::open_in_memory().expect("bot store");
        bot_store
            .record_dialog(DialogRecord {
                parent_chat_id: Some(InlineId::new(10)),
                parent_message_id: Some(InlineId::new(11)),
                ..DialogRecord::new(InlineId::new(20))
            })
            .await
            .expect("anchored child");
        bot_store
            .record_dialog(DialogRecord {
                parent_chat_id: Some(InlineId::new(10)),
                parent_message_id: None,
                ..DialogRecord::new(InlineId::new(30))
            })
            .await
            .expect("unanchored child");

        assert_eq!(
            resolve_reply_thread_scope(&bot_store, 20).await.unwrap(),
            ReplyThreadScope {
                current_chat_id: 20,
                scope_chat_id: 10,
                existing_reply_thread: true,
            }
        );
        assert_eq!(
            resolve_reply_thread_scope(&bot_store, 30).await.unwrap(),
            ReplyThreadScope {
                current_chat_id: 30,
                scope_chat_id: 30,
                existing_reply_thread: false,
            }
        );
    }

    #[tokio::test]
    async fn explicit_chat_override_wins_over_provider_default() {
        let store = BridgeStore::open_in_memory().expect("bridge store");
        let installation_id = InstallationId::new("codex").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation record");
        store
            .update_reply_thread_override(&installation_id, 10, None, Some(ReplyThreadMode::Off), 2)
            .expect("override");
        let bot_store = SqliteStore::open_in_memory().expect("bot store");
        let policy = resolve_reply_thread_policy(
            &store,
            &installation_id,
            &bot_store,
            ReplyThreadDefault {
                mode: ReplyThreadMode::On,
                source: ReplyThreadDefaultSource::Provider,
            },
            10,
        )
        .await
        .expect("policy");
        assert_eq!(policy.mode, ReplyThreadMode::Off);
        assert_eq!(policy.source, ReplyThreadPolicySource::ChatOverride);
        assert_eq!(policy.override_revision, Some(1));
    }
}
