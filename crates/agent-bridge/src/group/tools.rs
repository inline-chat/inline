//! Inline tools for agents (spec §4.8): served in-process, acting as the
//! agent, and bound to the agent and its work rather than the active turn.
//!
//! - A tool call is resolved through the session that issued it. Background
//!   tasks and native children keep the work's tools after the turn ends; a
//!   child session (a Codex sub-agent thread) resolves through its parent.
//! - Bindings end when the harness confirms the release, not when a turn ends.
//! - Mutations with side effects need explicit intent (`confirmed_intent`), as
//!   today. Chat text never grants authority.
//! - Links never broaden access: a target chat must already be accessible to
//!   the agent's bot.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::harness::{ChatId, SessionKey, UserId, WorkRef};

/// How a tool may choose its target chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolTarget {
    /// No chat target.
    None,
    /// Only the work's current publication chat.
    CurrentWork,
    /// Any chat the bot can already access (by id or link).
    Accessible,
}

/// One tool in the v2 catalog.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolDescriptor {
    pub name: &'static str,
    pub read_only: bool,
    /// Requires `confirmed_intent: true` from the model.
    pub needs_intent: bool,
    pub target: ToolTarget,
}

const fn read(name: &'static str, target: ToolTarget) -> ToolDescriptor {
    ToolDescriptor {
        name,
        read_only: true,
        needs_intent: false,
        target,
    }
}

const fn write(name: &'static str, target: ToolTarget, needs_intent: bool) -> ToolDescriptor {
    ToolDescriptor {
        name,
        read_only: false,
        needs_intent,
        target,
    }
}

/// The spec §4.8 catalog. Names already served by today's bridge keep their
/// names so native sessions keep working across the upgrade.
pub const TOOL_CATALOG: &[ToolDescriptor] = &[
    // Current context; read by link; search; threads I participate in.
    read("get_current_context", ToolTarget::None),
    read("get_chat", ToolTarget::Accessible),
    read("get_messages", ToolTarget::Accessible),
    read("get_history", ToolTarget::Accessible),
    read("read_link", ToolTarget::Accessible),
    read("search_messages", ToolTarget::Accessible),
    read("search_chats", ToolTarget::None),
    read("list_my_threads", ToolTarget::None),
    read("get_reactions", ToolTarget::Accessible),
    read("list_pins", ToolTarget::Accessible),
    // Send, reply, mention, react, pin.
    write("send_message", ToolTarget::Accessible, false),
    write("add_reaction", ToolTarget::Accessible, false),
    write("remove_reaction", ToolTarget::Accessible, false),
    write("pin_message", ToolTarget::Accessible, true),
    write("unpin_message", ToolTarget::Accessible, true),
    write("edit_own_message", ToolTarget::Accessible, true),
    // Create a thread; start a subthread; return an attachment; status.
    write("create_chat", ToolTarget::None, true),
    write("start_subthread", ToolTarget::CurrentWork, false),
    write("return_attachment", ToolTarget::CurrentWork, true),
    write("report_status", ToolTarget::CurrentWork, false),
    // Ask a teammate (a question mention in the current work).
    write("ask_teammate", ToolTarget::CurrentWork, false),
];

pub fn tool(name: &str) -> Option<&'static ToolDescriptor> {
    TOOL_CATALOG.iter().find(|tool| tool.name == name)
}

/// What a session's tool calls act for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolBinding {
    pub agent: UserId,
    pub work: WorkRef,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToolRejection {
    UnknownTool,
    /// The session is not bound to any work of this agent (never was, or
    /// its release was confirmed).
    UnboundSession,
    MissingIntent,
    /// The target is outside the current work, or not already accessible to
    /// the bot. A link never broadens access.
    TargetNotAccessible {
        chat: ChatId,
    },
}

/// Session → work bindings for one agent. Keyed by session, never by turn.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolBindings {
    sessions: BTreeMap<String, ToolBinding>,
    /// Child session → parent session.
    children: BTreeMap<String, String>,
}

fn key(session: &SessionKey) -> String {
    format!("{}/{}", session.provider, session.session)
}

impl ToolBindings {
    /// On open, resume or fork of a work's session.
    pub fn bind(&mut self, session: &SessionKey, binding: ToolBinding) {
        self.sessions.insert(key(session), binding);
    }

    /// A native child session acting for its parent's work.
    pub fn bind_child(&mut self, child: &SessionKey, parent: &SessionKey) {
        self.children.insert(key(child), key(parent));
    }

    /// The work moved its publication (subthread move).
    pub fn move_work(&mut self, session: &SessionKey, chat: ChatId) {
        if let Some(binding) = self.sessions.get_mut(&key(session)) {
            binding.work.chat = chat;
        }
    }

    /// Only after the harness confirms the release (`NativeReleased`).
    pub fn unbind(&mut self, session: &SessionKey) {
        let parent = key(session);
        self.sessions.remove(&parent);
        self.children.retain(|_, owner| *owner != parent);
        self.children.remove(&parent);
    }

    pub fn resolve(&self, session: &SessionKey) -> Option<&ToolBinding> {
        let session = key(session);
        let owner = self.children.get(&session).unwrap_or(&session);
        self.sessions.get(owner)
    }

    /// Authorizes one call. `bot_can_access` answers from the bot's own
    /// membership, never from a link in the arguments.
    pub fn authorize(
        &self,
        session: &SessionKey,
        tool_name: &str,
        target: Option<ChatId>,
        confirmed_intent: bool,
        bot_can_access: impl Fn(ChatId) -> bool,
    ) -> Result<&ToolBinding, ToolRejection> {
        let tool = tool(tool_name).ok_or(ToolRejection::UnknownTool)?;
        let binding = self.resolve(session).ok_or(ToolRejection::UnboundSession)?;
        if tool.needs_intent && !confirmed_intent {
            return Err(ToolRejection::MissingIntent);
        }
        let chat = target.unwrap_or(binding.work.chat);
        let allowed = match tool.target {
            ToolTarget::None => true,
            ToolTarget::CurrentWork => chat == binding.work.chat,
            ToolTarget::Accessible => chat == binding.work.chat || bot_can_access(chat),
        };
        if !allowed {
            return Err(ToolRejection::TargetNotAccessible { chat });
        }
        Ok(binding)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProviderId, ProviderSessionId};

    fn session(id: &str) -> SessionKey {
        SessionKey {
            provider: ProviderId::new("codex").unwrap(),
            session: ProviderSessionId::new(id).unwrap(),
        }
    }

    fn binding(chat: i64) -> ToolBinding {
        ToolBinding {
            agent: UserId(99),
            work: WorkRef {
                chat: ChatId(chat),
                session: Some(ProviderSessionId::new("thr").unwrap()),
            },
        }
    }

    fn nothing_else(_: ChatId) -> bool {
        false
    }

    #[test]
    fn catalog_covers_the_spec_and_names_are_unique() {
        for name in [
            "get_current_context",
            "read_link",
            "search_messages",
            "list_my_threads",
            "send_message",
            "add_reaction",
            "pin_message",
            "create_chat",
            "start_subthread",
            "return_attachment",
            "report_status",
            "ask_teammate",
        ] {
            assert!(tool(name).is_some(), "{name}");
        }
        let mut names = TOOL_CATALOG
            .iter()
            .map(|tool| tool.name)
            .collect::<Vec<_>>();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), TOOL_CATALOG.len());
        assert!(
            TOOL_CATALOG
                .iter()
                .filter(|tool| tool.read_only)
                .all(|tool| !tool.needs_intent)
        );
    }

    #[test]
    fn calls_resolve_by_session_not_turn_including_children() {
        let mut bindings = ToolBindings::default();
        bindings.bind(&session("thr"), binding(5));
        bindings.bind_child(&session("sub-agent"), &session("thr"));
        // A background task after the turn ended: same session, still bound.
        assert_eq!(bindings.resolve(&session("thr")), Some(&binding(5)));
        assert_eq!(bindings.resolve(&session("sub-agent")), Some(&binding(5)));
        assert_eq!(bindings.resolve(&session("other")), None);
        // The subthread move updates where the work publishes.
        bindings.move_work(&session("thr"), ChatId(6));
        assert_eq!(
            bindings.resolve(&session("sub-agent")).unwrap().work.chat,
            ChatId(6)
        );
        // Only a confirmed release unbinds, children included.
        bindings.unbind(&session("thr"));
        assert_eq!(bindings.resolve(&session("thr")), None);
        assert_eq!(bindings.resolve(&session("sub-agent")), None);
    }

    #[test]
    fn links_never_broaden_access() {
        let mut bindings = ToolBindings::default();
        bindings.bind(&session("thr"), binding(5));
        let call = |name, target, intent, access: &dyn Fn(ChatId) -> bool| {
            bindings.authorize(&session("thr"), name, target, intent, access)
        };
        assert!(call("get_messages", None, false, &nothing_else).is_ok());
        assert_eq!(
            call("read_link", Some(ChatId(77)), false, &nothing_else),
            Err(ToolRejection::TargetNotAccessible { chat: ChatId(77) })
        );
        assert!(
            call("read_link", Some(ChatId(77)), false, &|chat| chat
                == ChatId(77))
            .is_ok()
        );
        // Current-work tools never leave the work's chat.
        assert_eq!(
            call("report_status", Some(ChatId(77)), false, &|_| true),
            Err(ToolRejection::TargetNotAccessible { chat: ChatId(77) })
        );
    }

    #[test]
    fn side_effects_need_explicit_intent() {
        let mut bindings = ToolBindings::default();
        bindings.bind(&session("thr"), binding(5));
        assert_eq!(
            bindings.authorize(&session("thr"), "pin_message", None, false, nothing_else),
            Err(ToolRejection::MissingIntent)
        );
        assert!(
            bindings
                .authorize(&session("thr"), "pin_message", None, true, nothing_else)
                .is_ok()
        );
        assert!(
            bindings
                .authorize(&session("thr"), "send_message", None, false, nothing_else)
                .is_ok()
        );
    }

    #[test]
    fn unknown_tools_and_unbound_sessions_are_rejected() {
        let bindings = ToolBindings::default();
        assert_eq!(
            bindings.authorize(&session("thr"), "rm_rf", None, true, nothing_else),
            Err(ToolRejection::UnknownTool)
        );
        assert_eq!(
            bindings.authorize(&session("thr"), "get_chat", None, false, nothing_else),
            Err(ToolRejection::UnboundSession)
        );
    }
}
