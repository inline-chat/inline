//! Provider-neutral bot capability and chat-settings request contracts.

use serde::{Deserialize, Serialize};

use crate::{BotSettingsValue, InlineId, PeerRef};

/// Capability advertised by the authenticated bot account.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotCapability {
    /// Capability family.
    pub kind: BotCapabilityKind,
    /// Contract version supported by the bot.
    pub version: u32,
}

/// Supported bot capability families.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum BotCapabilityKind {
    /// Per-chat bot settings exposed by Inline clients.
    ChatSettings,
}

/// Request to fetch one bot's settings document for a chat.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestBotChatSettingsRequest {
    /// Chat or peer where the bot settings are being shown.
    pub peer: PeerRef,
    /// Bot account whose settings are requested.
    pub bot_user_id: InlineId,
    /// Settings contract version supported by the requesting client.
    pub version: u32,
}

/// Request to invoke one item in the bot's current settings document.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InvokeBotChatSettingsItemRequest {
    /// Chat or peer where the setting is being changed.
    pub peer: PeerRef,
    /// Bot account whose setting is invoked.
    pub bot_user_id: InlineId,
    /// Settings contract version supported by the requesting client.
    pub version: u32,
    /// Stable bot-owned item identifier.
    pub item_id: String,
    /// Optional new control value.
    pub value: Option<BotSettingsValue>,
    /// Revision rendered before the invocation.
    pub document_revision: String,
}

/// Bot-side answer to a pending settings request or invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswerBotChatSettingsRequest {
    /// Broker request ID from [`crate::BotInteractionEvent`].
    pub request_id: u64,
    /// Settings result returned to the requesting Inline client.
    pub response: BotChatSettingsResponse,
}

/// Result of requesting or invoking bot chat settings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum BotChatSettingsResponse {
    /// Current settings document.
    Document(BotChatSettingsDocument),
    /// Safe user-facing problem response.
    Problem(BotChatSettingsProblem),
}

/// Bot-owned, plain-text settings document.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsDocument {
    /// Settings contract version.
    pub version: u32,
    /// Opaque revision used to reject stale mutations.
    pub revision: String,
    /// Ordered settings sections.
    pub sections: Vec<BotChatSettingsSection>,
}

/// Logical settings group.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsSection {
    /// Stable bot-owned section identifier.
    pub id: String,
    /// Optional display title.
    pub title: Option<String>,
    /// Optional plain-text description.
    pub description: Option<String>,
    /// Ordered controls in this section.
    pub items: Vec<BotChatSettingsItem>,
}

/// One settings row and its typed control.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsItem {
    /// Stable bot-owned item identifier.
    pub id: String,
    /// Optional display label.
    pub label: Option<String>,
    /// Optional plain-text description.
    pub description: Option<String>,
    /// Whether the item is currently disabled.
    pub disabled: bool,
    /// Optional explanation for a disabled item.
    pub disabled_reason: Option<String>,
    /// Typed control rendered for this item.
    pub control: BotChatSettingsControl,
}

/// Supported bot-settings controls.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum BotChatSettingsControl {
    /// Boolean toggle.
    Toggle {
        /// Current toggle value.
        value: bool,
    },
    /// Single-choice selector.
    Select {
        /// Current opaque value.
        value: String,
        /// Available choices.
        options: Vec<BotChatSettingsSelectOption>,
    },
    /// Plain-text informational row.
    Info {
        /// User-facing plain text.
        text: String,
        /// Semantic presentation tone.
        tone: BotChatSettingsInfoTone,
    },
    /// Action button.
    Button,
    /// Host-local workspace selector using opaque identifiers only.
    Folder(BotChatSettingsFolder),
}

/// Select control option.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsSelectOption {
    /// Opaque bot-owned value.
    pub value: String,
    /// Display label.
    pub label: String,
    /// Optional plain-text description.
    pub description: Option<String>,
    /// Whether this choice is disabled.
    pub disabled: bool,
}

/// Semantic tone for an informational settings row.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum BotChatSettingsInfoTone {
    /// Neutral guidance.
    Neutral,
    /// Successful or healthy state.
    Success,
    /// Warning state.
    Warning,
    /// Error state.
    Error,
}

/// Host-local folder selector metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsFolder {
    /// Current opaque host-owned workspace identifier.
    pub value: String,
    /// Recently used opaque workspaces.
    pub recent_folders: Vec<BotChatSettingsFolderOption>,
    /// Stable host installation identifier.
    pub host_installation_id: String,
    /// Human-readable host label.
    pub host_label: String,
    /// Whether the host can open a native local picker.
    pub allows_local_picker: bool,
    /// Ephemeral loopback port, present only while local picking is enabled.
    pub local_picker_port: Option<u32>,
    /// Opaque per-service-epoch loopback capability, never a filesystem path.
    pub local_picker_capability: Option<String>,
}

/// Recent folder choice. Filesystem paths must not be placed in these fields.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsFolderOption {
    /// Opaque host-owned workspace identifier.
    pub value: String,
    /// Human-readable folder label.
    pub label: String,
    /// Optional non-sensitive parent hint.
    pub parent_hint: Option<String>,
    /// Whether the option is disabled.
    pub disabled: bool,
}

/// Safe problem response returned instead of a settings document.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotChatSettingsProblem {
    /// Stable problem category.
    pub code: BotChatSettingsProblemCode,
    /// Concise user-facing message.
    pub message: String,
    /// Current document, when useful for stale or invalid mutations.
    pub current_document: Option<BotChatSettingsDocument>,
}

/// Stable settings problem categories.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum BotChatSettingsProblemCode {
    /// Settings are temporarily unavailable.
    Unavailable,
    /// Supplied control value was invalid.
    InvalidValue,
    /// The caller used a stale document revision.
    Stale,
    /// The bot failed to apply or load the setting.
    Failed,
    /// No capable bot connection answered before the broker deadline.
    Unreachable,
}
