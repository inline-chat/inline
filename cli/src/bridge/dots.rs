//! ChatGPT Dots bridge: an Inline bot that stands in for the owner's Dot.
//!
//! Runs as one provider installation of the owner's bridge service, so it
//! shares setup, the launchd/systemd service, health, and logs with the
//! coding-agent bridges. Unlike them it has no turns to run: it hands the bot
//! DM to the provider-neutral [`inline_relay::Relay`] with the Dots connector.

use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use inline_client::{
    AnswerMessageActionRequest, ClientEvent, ClientStore, EditInteractiveMessageRequest,
    EditMessageRequest, ExternalId, InlineClient, InlineId, LosslessEventReceiver, MediaKind,
    MessageActionButton, MessageActionKind, MessageActionRow, MessageActions, MessageContent,
    PeerRef, ReactRequest, SendInteractiveTextRequest, SendNotificationMode, SendTextRequest,
    SqliteStore, TypingRequest, UploadRequest,
};
use inline_dots::{
    CodexAppServerTokenSource, ConnectorSettings, DotsClient, DotsConfig, DotsConnector,
};
use inline_relay::{
    BoxFuture, Button, FileData, InlineError, InlineEvent, InlineMedia, InlinePost, InlineResult,
    InlineSide, Relay, RelayConfig, RelayHealth, RelayStore,
};
use sha2::{Digest, Sha256};

use super::account::ProviderInstallationConfig;
use super::helpers::interaction_random_id;
use super::supervisor::{ProviderConnectionLease, ProviderReadiness};

/// Provider id of the Dots bridge.
pub(crate) const DOTS_PROVIDER_ID: &str = "dots";
/// Default bot name when the Dot has none.
pub(crate) const DOTS_DISPLAY_NAME: &str = "ChatGPT Dot";
const EXTERNAL_SOURCE: &str = "dots-bridge";

/// The bot's side of the owner DM, on the bridge's `InlineClient`.
pub(crate) struct BotDm {
    bot: InlineClient,
    store: SqliteStore,
    chat_id: InlineId,
    http: reqwest::Client,
    profile: Option<ProfileSync>,
    /// The owner's session: posts, edits, and reactions the owner made in
    /// ChatGPT appear in Inline as the owner's own.
    owner: Option<Arc<super::owner_control::OwnerControl>>,
}

/// Mirrors the Dot's name and photo onto the bot through a short-lived owner
/// session (bot profiles are owner-managed). Only fields still managed by
/// the bridge change: a name or photo the owner set by hand is kept.
pub(crate) struct ProfileSync {
    pub(crate) config: crate::config::Config,
    pub(crate) owner_auth: inline_client::AuthCredential,
    pub(crate) bot_user_id: i64,
    pub(crate) state_dir: std::path::PathBuf,
    pub(crate) bundled_avatar_id: Option<String>,
}

/// Marker holding the bot name the bridge last set (absent when the owner
/// chose a name at setup).
pub(crate) const MANAGED_NAME_FILE: &str = "dots-managed-name";
const MANAGED_AVATAR_FILE: &str = "dots-managed-avatar";

impl ProfileSync {
    fn marker(&self, file: &str) -> Option<String> {
        std::fs::read_to_string(self.state_dir.join(file))
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
    }

    fn set_marker(&self, file: &str, value: &str) -> io::Result<()> {
        std::fs::write(self.state_dir.join(file), value)
    }

    async fn apply(&self, name: Option<&str>, avatar: Option<&FileData>) -> Result<(), String> {
        use inline_protocol::proto;
        let mut owner =
            crate::owner_session::OwnerSession::connect(&self.config, self.owner_auth.clone())
                .await
                .map_err(|error| error.to_string())?;
        let bots = owner
            .call(proto::ListBotsInput {})
            .await
            .map_err(|error| error.to_string())?
            .bots;
        let bot = bots
            .into_iter()
            .find(|bot| bot.id == self.bot_user_id)
            .ok_or_else(|| "the bridge bot no longer exists".to_owned())?;
        if let Some(name) = name {
            let current = bot.first_name.as_deref().unwrap_or("").trim().to_owned();
            if current != name {
                let Some(managed) = self.marker(MANAGED_NAME_FILE) else {
                    return Ok(());
                };
                if current != managed {
                    // Renamed by hand; stop following the Dot's name.
                    return Ok(());
                }
                owner
                    .call(proto::UpdateBotProfileInput {
                        bot_user_id: self.bot_user_id,
                        name: Some(name.to_owned()),
                        photo_file_unique_id: None,
                        username: None,
                    })
                    .await
                    .map_err(|error| error.to_string())?;
            }
            self.set_marker(MANAGED_NAME_FILE, name)
                .map_err(|error| error.to_string())?;
        }
        if let Some(avatar) = avatar {
            let current = bot
                .profile_photo
                .as_ref()
                .and_then(|photo| photo.file_unique_id.clone());
            let managed = self
                .marker(MANAGED_AVATAR_FILE)
                .or_else(|| self.bundled_avatar_id.clone());
            if current.is_some() && current != managed {
                return Ok(());
            }
            let path = self.state_dir.join("dots-avatar-upload");
            tokio::fs::write(&path, &avatar.bytes)
                .await
                .map_err(|error| error.to_string())?;
            let upload = owner
                .upload(inline_sdk::NativeUploadInput::new(
                    &path,
                    &avatar.name,
                    &avatar.mime,
                    proto::UploadKind::Photo,
                ))
                .await
                .map_err(|error| error.to_string());
            let _ = tokio::fs::remove_file(&path).await;
            let upload = upload?;
            owner
                .call(proto::UpdateBotProfileInput {
                    bot_user_id: self.bot_user_id,
                    name: None,
                    photo_file_unique_id: Some(upload.file_unique_id.clone()),
                    username: None,
                })
                .await
                .map_err(|error| error.to_string())?;
            self.set_marker(MANAGED_AVATAR_FILE, &upload.file_unique_id)
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

impl BotDm {
    pub(crate) fn new(
        bot: InlineClient,
        store: SqliteStore,
        chat_id: InlineId,
        profile: Option<ProfileSync>,
        owner: Option<Arc<super::owner_control::OwnerControl>>,
    ) -> io::Result<Self> {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(io::Error::other)?;
        Ok(Self {
            bot,
            store,
            chat_id,
            http,
            profile,
            owner,
        })
    }

    fn external(key: &str) -> InlineResult<ExternalId> {
        let digest = Sha256::digest(key.as_bytes());
        let id: String = digest[..16]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        ExternalId::try_new(EXTERNAL_SOURCE, id).map_err(|error| InlineError(error.to_string()))
    }

    fn actions(rows: &[Vec<Button>]) -> MessageActions {
        MessageActions {
            rows: rows
                .iter()
                .map(|row| MessageActionRow {
                    actions: row
                        .iter()
                        .map(|button| MessageActionButton {
                            action_id: button.id.clone(),
                            text: button.label.clone(),
                            kind: MessageActionKind::Callback {
                                data: button.data.clone(),
                            },
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

fn inline_error(error: impl std::fmt::Display) -> InlineError {
    InlineError(super::safe_diagnostic(&error.to_string()))
}

fn media_kind(mime: &str) -> MediaKind {
    match mime.split(';').next().unwrap_or("").trim() {
        "image/jpeg" | "image/png" | "image/gif" | "image/webp" => MediaKind::Photo,
        _ => MediaKind::Document,
    }
}

/// Writes Inline's formatting entities back as Markdown, so a link or code
/// the owner sends from Inline reaches the agent intact. Offsets are UTF-16.
pub(crate) fn entities_to_markdown(
    text: &str,
    entities: &[inline_client::MessageEntityRecord],
) -> String {
    if entities.is_empty() {
        return text.to_owned();
    }
    // UTF-16 offset of every char boundary, so entity ranges map to bytes.
    let mut boundaries = Vec::with_capacity(text.len() + 1);
    let mut units = 0i64;
    for (byte, character) in text.char_indices() {
        boundaries.push((units, byte));
        units += character.len_utf16() as i64;
    }
    boundaries.push((units, text.len()));
    let byte_at = |offset: i64| {
        boundaries
            .iter()
            .find(|(unit, _)| *unit >= offset)
            .map(|(_, byte)| *byte)
            .unwrap_or(text.len())
    };
    // (byte, is_close, nesting key, marker)
    let mut marks: Vec<(usize, bool, i64, String)> = Vec::new();
    for entity in entities {
        let (open, close) = match entity.kind.as_str() {
            "TYPE_BOLD" => ("**".to_owned(), "**".to_owned()),
            "TYPE_ITALIC" => ("_".to_owned(), "_".to_owned()),
            "TYPE_STRIKETHROUGH" => ("~~".to_owned(), "~~".to_owned()),
            "TYPE_CODE" => ("`".to_owned(), "`".to_owned()),
            "TYPE_PRE" => ("```\n".to_owned(), "\n```".to_owned()),
            "TYPE_TEXT_URL" => match entity.value.as_deref().filter(|url| !url.is_empty()) {
                Some(url) => ("[".to_owned(), format!("]({url})")),
                None => continue,
            },
            // Commands keep who they name, for `/share @name`.
            "TYPE_MENTION" if text.trim_start().starts_with('/') => match entity.user_id {
                Some(user) => (
                    "[".to_owned(),
                    format!("](inline://user?id={})", user.get()),
                ),
                None => continue,
            },
            // Mentions, plain URLs, and emails are already in the text.
            _ => continue,
        };
        if entity.length <= 0 {
            continue;
        }
        let start = byte_at(entity.offset);
        let end = byte_at(entity.offset + entity.length);
        if start >= end {
            continue;
        }
        marks.push((start, false, -entity.length, open));
        marks.push((end, true, entity.length, close));
    }
    // Closes before opens at the same spot; outer entities open first and
    // close last.
    marks.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(a.2.cmp(&b.2)));
    let mut out = String::with_capacity(text.len() + marks.len() * 4);
    let mut cursor = 0;
    for (byte, _, _, marker) in marks {
        out.push_str(&text[cursor..byte]);
        out.push_str(&marker);
        cursor = byte;
    }
    out.push_str(&text[cursor..]);
    out
}

impl BotDm {
    async fn send_post(&self, chat_id: InlineId, post: &InlinePost) -> InlineResult<i64> {
        {
            let external_id = Self::external(&post.key)?;
            let random_id = interaction_random_id("dots", &post.key);
            let owner = post
                .as_owner
                .then(|| self.owner.as_ref().map(|owner| owner.client()))
                .flatten();
            let client = owner.unwrap_or(&self.bot);
            // Without an owner session, fall back to a labeled bot post.
            let fallback_text;
            let text = if post.as_owner && owner.is_none() && !post.text.is_empty() {
                fallback_text = inline_relay::render::owner_mirror("ChatGPT", &post.text);
                fallback_text.as_str()
            } else {
                post.text.as_str()
            };
            let notification_mode = if post.silent {
                SendNotificationMode::Silent
            } else {
                SendNotificationMode::Normal
            };
            let peer = PeerRef::Chat { chat_id };
            let reply_to_message_id = post.reply_to.map(InlineId::new);
            let mutation = if let Some(file) = &post.file {
                let request = UploadRequest {
                    peer,
                    kind: media_kind(&file.mime),
                    file_name: Some(file.name.clone()),
                    mime_type: Some(file.mime.clone()),
                    size_bytes: Some(file.bytes.len() as u64),
                    caption: (!text.trim().is_empty()).then(|| text.to_owned()),
                    width: None,
                    height: None,
                    duration_ms: None,
                    external_id: Some(external_id),
                    random_id: Some(random_id),
                    reply_to_message_id,
                };
                client
                    .send_media(request, file.bytes.clone())
                    .await
                    .map_err(inline_error)?
            } else {
                let mut message = SendTextRequest::new(peer, text);
                message.reply_to_message_id = reply_to_message_id;
                message.external_id = Some(external_id);
                message.random_id = Some(random_id);
                message.parse_markdown = true;
                message.notification_mode = notification_mode;
                if post.buttons.is_empty() {
                    client.send_text(message).await.map_err(inline_error)?
                } else {
                    self.bot
                        .send_interactive_text(SendInteractiveTextRequest {
                            message,
                            actions: Self::actions(&post.buttons),
                        })
                        .await
                        .map_err(inline_error)?
                }
            };
            mutation
                .message_id
                .map(InlineId::get)
                .ok_or_else(|| InlineError("Inline accepted the message without an id".into()))
        }
    }

    async fn edit_text(
        &self,
        chat_id: InlineId,
        message_id: i64,
        text: &str,
        buttons: Option<&[Vec<Button>]>,
    ) -> InlineResult<()> {
        let message = EditMessageRequest {
            chat_id,
            message_id: InlineId::new(message_id),
            text: text.to_owned(),
            external_id: None,
            parse_markdown: true,
        };
        match buttons {
            None => self.bot.edit_message(message).await.map_err(inline_error),
            // Sending the action set lets an edit clear buttons.
            Some(rows) => self
                .bot
                .edit_interactive_message(EditInteractiveMessageRequest {
                    message,
                    actions: Self::actions(rows),
                })
                .await
                .map_err(inline_error),
        }
    }

    /// `/share`, `/unshare`, `/allowlist`: who else may use this Dot, kept as
    /// agent grants in Inline like the other bridges.
    async fn share_command(&self, name: &str, arguments: &str) -> InlineResult<Option<String>> {
        let remove = match name {
            "share" => false,
            "unshare" => true,
            "allowlist" => arguments
                .split_whitespace()
                .next()
                .is_some_and(|word| word.eq_ignore_ascii_case("remove")),
            _ => return Ok(None),
        };
        let users = command_user_ids(arguments);
        if users.is_empty() {
            let grants = super::v2::api::list_grants(&self.bot)
                .await
                .map_err(inline_error)?
                .grants;
            if grants.is_empty() {
                return Ok(Some(
                    "Only you can use this Dot. Add someone with /share @name.".into(),
                ));
            }
            let mut names = Vec::new();
            for grant in grants {
                names.push(self.user_name(grant.user_id).await);
            }
            return Ok(Some(format!(
                "People who can use this Dot: {}. Remove someone with /unshare @name.",
                names.join(", ")
            )));
        }
        let mut done = Vec::new();
        for user in users {
            if remove {
                super::v2::api::delete_grant(&self.bot, user).await
            } else {
                super::v2::api::grant_use(&self.bot, user).await
            }
            .map_err(inline_error)?;
            done.push(self.user_name(user).await);
        }
        Ok(Some(if remove {
            format!("{} can no longer use this Dot.", done.join(", "))
        } else {
            format!(
                "{} can now use this Dot: in a DM with this bot, or by mentioning it in a chat. Their messages reach your Dot labelled with their name, and its answers go back to them.",
                done.join(", ")
            )
        }))
    }

    async fn user_name(&self, user_id: i64) -> String {
        user_display_name(&self.store, user_id).await
    }
}

/// A user's name as the bot knows it, falling back to their id.
async fn user_display_name(store: &SqliteStore, user_id: i64) -> String {
    let user = store.user(InlineId::new(user_id)).await.ok().flatten();
    user.and_then(|user| {
        let full = [user.first_name.as_deref(), user.last_name.as_deref()]
            .into_iter()
            .flatten()
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        (!full.is_empty())
            .then_some(full)
            .or_else(|| user.username.map(|name| format!("@{name}")))
    })
    .unwrap_or_else(|| format!("user {user_id}"))
}

/// User ids in command arguments: mention links (`inline://user?id=N`) and
/// bare numbers.
pub(crate) fn command_user_ids(arguments: &str) -> Vec<i64> {
    let mut ids = Vec::new();
    for (index, _) in arguments.match_indices("inline://user?id=") {
        let digits: String = arguments[index + "inline://user?id=".len()..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        ids.extend(digits.parse::<i64>().ok());
    }
    for word in arguments.split_whitespace() {
        ids.extend(word.parse::<i64>().ok().filter(|id| *id > 0));
    }
    ids.sort_unstable();
    ids.dedup();
    ids
}

impl InlineSide for BotDm {
    fn post<'a>(&'a self, post: &'a InlinePost) -> BoxFuture<'a, InlineResult<i64>> {
        Box::pin(self.send_post(self.chat_id, post))
    }

    fn post_in<'a>(
        &'a self,
        chat_id: i64,
        post: &'a InlinePost,
    ) -> BoxFuture<'a, InlineResult<i64>> {
        Box::pin(async move {
            // Guests only ever get bot posts.
            let post = InlinePost {
                as_owner: false,
                ..post.clone()
            };
            self.send_post(InlineId::new(chat_id), &post).await
        })
    }

    fn edit_in<'a>(
        &'a self,
        chat_id: i64,
        message_id: i64,
        text: &'a str,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(self.edit_text(InlineId::new(chat_id), message_id, text, None))
    }

    fn command<'a>(
        &'a self,
        name: &'a str,
        arguments: &'a str,
    ) -> BoxFuture<'a, InlineResult<Option<String>>> {
        Box::pin(self.share_command(name, arguments))
    }

    fn edit_as_owner<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            let Some(owner) = &self.owner else {
                return self.edit(message_id, text, None).await;
            };
            owner
                .client()
                .edit_message(EditMessageRequest {
                    chat_id: self.chat_id,
                    message_id: InlineId::new(message_id),
                    text: text.to_owned(),
                    external_id: None,
                    parse_markdown: true,
                })
                .await
                .map_err(inline_error)
        })
    }

    fn react_as_owner<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            // A bot reaction would misattribute it; skip without a session.
            let Some(owner) = &self.owner else {
                return Ok(());
            };
            owner
                .client()
                .react(ReactRequest {
                    chat_id: self.chat_id,
                    message_id: InlineId::new(message_id),
                    reaction: emoji.to_owned(),
                    remove,
                    external_id: None,
                })
                .await
                .map_err(inline_error)
        })
    }

    fn edit<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
        buttons: Option<&'a [Vec<Button>]>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(self.edit_text(self.chat_id, message_id, text, buttons))
    }

    fn react<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.bot
                .react(ReactRequest {
                    chat_id: self.chat_id,
                    message_id: InlineId::new(message_id),
                    reaction: emoji.to_owned(),
                    remove,
                    external_id: None,
                })
                .await
                .map_err(inline_error)
        })
    }

    fn typing(&self, active: bool) -> BoxFuture<'_, InlineResult<()>> {
        Box::pin(async move {
            self.bot
                .typing(TypingRequest {
                    chat_id: self.chat_id,
                    is_typing: active,
                })
                .await
                .map_err(inline_error)
        })
    }

    fn answer_action<'a>(
        &'a self,
        interaction_id: i64,
        toast: Option<&'a str>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.bot
                .answer_message_action(AnswerMessageActionRequest {
                    interaction_id: InlineId::new(interaction_id),
                    toast: toast.map(str::to_owned),
                })
                .await
                .map_err(inline_error)
        })
    }

    fn mark_read(&self, message_id: i64) -> BoxFuture<'_, InlineResult<()>> {
        Box::pin(async move {
            self.bot
                .read(inline_client::ReadRequest {
                    chat_id: self.chat_id,
                    max_message_id: Some(InlineId::new(message_id)),
                })
                .await
                .map_err(inline_error)
        })
    }

    fn update_profile<'a>(
        &'a self,
        name: Option<&'a str>,
        avatar: Option<&'a FileData>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            let Some(profile) = &self.profile else {
                return Ok(());
            };
            profile.apply(name, avatar).await.map_err(inline_error)
        })
    }

    fn fetch_media<'a>(
        &'a self,
        media: &'a InlineMedia,
        limit: usize,
    ) -> BoxFuture<'a, InlineResult<FileData>> {
        Box::pin(async move {
            if media.size.is_some_and(|size| size as usize > limit) {
                return Err(InlineError(format!(
                    "the file is larger than {} MiB",
                    limit / 1024 / 1024
                )));
            }
            let url = media
                .url
                .as_deref()
                .and_then(|url| reqwest::Url::parse(url).ok())
                .filter(|url| url.scheme() == "https")
                .ok_or_else(|| InlineError("the file has no download link yet".into()))?;
            let response = self.http.get(url).send().await.map_err(|error| {
                InlineError(super::safe_diagnostic(&error.without_url().to_string()))
            })?;
            if !response.status().is_success() {
                return Err(InlineError(format!(
                    "download failed with HTTP {}",
                    response.status().as_u16()
                )));
            }
            let header_mime = response
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .map(|value| value.split(';').next().unwrap_or("").trim().to_owned());
            let mut bytes = Vec::new();
            let mut stream = response.bytes_stream();
            use futures_util::StreamExt;
            while let Some(chunk) = stream.next().await {
                let chunk = chunk.map_err(|error| {
                    InlineError(super::safe_diagnostic(&error.without_url().to_string()))
                })?;
                if bytes.len() + chunk.len() > limit {
                    return Err(InlineError(format!(
                        "the file is larger than {} MiB",
                        limit / 1024 / 1024
                    )));
                }
                bytes.extend_from_slice(&chunk);
            }
            let mime = media
                .mime
                .clone()
                .filter(|mime| !mime.is_empty())
                .or(header_mime)
                .unwrap_or_else(|| "application/octet-stream".into());
            Ok(FileData {
                name: media.name.clone().unwrap_or_else(|| "file".into()),
                mime,
                bytes,
            })
        })
    }
}

/// A text message to the Dot from someone other than the owner: in their DM
/// with the bot, or a chat where they mentioned it. Whether they may use it
/// is checked separately.
pub(crate) struct GuestCandidate {
    pub(crate) chat_id: i64,
    pub(crate) message_id: i64,
    pub(crate) sender_id: i64,
    pub(crate) mentioned: bool,
    pub(crate) text: String,
}

pub(crate) fn guest_candidate(
    event: &ClientEvent,
    dm_chat_id: InlineId,
    owner_user_id: i64,
) -> Option<GuestCandidate> {
    let ClientEvent::MessageStored { message } = event else {
        return None;
    };
    if message.chat_id == dm_chat_id
        || message.is_outgoing
        || message.metadata.is_service
        || message.sender_id.get() == owner_user_id
    {
        return None;
    }
    let MessageContent::Text { text } = &message.content else {
        return None;
    };
    Some(GuestCandidate {
        chat_id: message.chat_id.get(),
        message_id: message.message_id.get(),
        sender_id: message.sender_id.get(),
        mentioned: message.metadata.mentioned == Some(true),
        text: entities_to_markdown(text, &message.metadata.entities),
    })
}

/// Turns a candidate into a relay event when the sender may use the Dot.
/// People need it shared with them; any chat but their own DM with the bot
/// also needs a mention. The owner's own messages elsewhere are ignored.
async fn admit_guest(
    bot: &InlineClient,
    store: &SqliteStore,
    candidate: GuestCandidate,
) -> Option<InlineEvent> {
    let dialog = store
        .dialog(InlineId::new(candidate.chat_id))
        .await
        .ok()
        .flatten();
    let direct = dialog
        .as_ref()
        .and_then(|dialog| dialog.peer_user_id)
        .is_some_and(|peer| peer.get() == candidate.sender_id);
    if !direct && !candidate.mentioned {
        return None;
    }
    let allowed = match super::v2::api::get_agent_access(bot, 0, candidate.sender_id).await {
        Ok(access) => {
            access.is_owner
                || access
                    .operations
                    .contains(&(inline_protocol::proto::AgentGrantOperation::Invoke as i32))
        }
        Err(error) => {
            log::warn!(target: "inline::bridge::dots", "access check failed: {error}");
            false
        }
    };
    if !allowed {
        if direct {
            let mut reply = SendTextRequest::new(
                PeerRef::Chat {
                    chat_id: InlineId::new(candidate.chat_id),
                },
                "This Dot hasn't been shared with you. Its owner can share it with /share.",
            );
            reply.reply_to_message_id = Some(InlineId::new(candidate.message_id));
            if let Ok(external_id) = BotDm::external(&format!(
                "guest-denied:{}:{}",
                candidate.chat_id, candidate.message_id
            )) {
                reply.external_id = Some(external_id);
            }
            if let Err(error) = bot.send_text(reply).await {
                log::warn!(target: "inline::bridge::dots", "denial not sent: {error}");
            }
        }
        return None;
    }
    let chat_title = (!direct)
        .then(|| dialog.and_then(|dialog| dialog.title))
        .flatten();
    Some(InlineEvent::Guest {
        chat_id: candidate.chat_id,
        message_id: candidate.message_id,
        sender_name: user_display_name(store, candidate.sender_id).await,
        chat_title,
        text: candidate.text,
    })
}

/// Maps a bot client event to a relay event for the owner DM. Events from
/// other chats, from the bot itself, and service rows are dropped.
pub(crate) fn relay_event(event: &ClientEvent, dm_chat_id: InlineId) -> Option<InlineEvent> {
    match event {
        ClientEvent::MessageStored { message } => {
            if message.chat_id != dm_chat_id || message.is_outgoing || message.metadata.is_service {
                return None;
            }
            let edited = message.metadata.edit_timestamp.is_some();
            // Edited messages arrive as the same id; the relay sends each id
            // once, so an edit of a delivered message is not resent, while a
            // message edited before the bridge saw it goes out as edited.
            let (text, media) = match &message.content {
                MessageContent::Text { text } => {
                    (entities_to_markdown(text, &message.metadata.entities), None)
                }
                MessageContent::Media {
                    url,
                    mime_type,
                    file_name,
                    caption,
                    size_bytes,
                    ..
                } => (
                    entities_to_markdown(
                        caption.as_deref().unwrap_or_default(),
                        &message.metadata.entities,
                    ),
                    Some(InlineMedia {
                        url: url.clone(),
                        name: file_name.clone(),
                        mime: mime_type.clone(),
                        size: *size_bytes,
                    }),
                ),
                // Visible rather than silently dropped.
                _ => {
                    return Some(InlineEvent::Unsupported {
                        message_id: message.message_id.get(),
                        sender_id: message.sender_id.get(),
                    });
                }
            };
            Some(InlineEvent::Message {
                message_id: message.message_id.get(),
                sender_id: message.sender_id.get(),
                text,
                reply_to: message.reply_to_message_id.map(InlineId::get),
                media,
                edited,
            })
        }
        ClientEvent::MessageDeleted {
            chat_id,
            message_id,
        } if *chat_id == dm_chat_id => Some(InlineEvent::Deleted {
            message_id: message_id.get(),
        }),
        ClientEvent::Typing {
            chat_id,
            user_id,
            is_typing,
        } if *chat_id == dm_chat_id => Some(InlineEvent::Typing {
            user_id: user_id.get(),
            active: *is_typing,
        }),
        ClientEvent::ReactionChanged {
            chat_id,
            message_id,
            user_id,
            reaction,
            removed,
        } if *chat_id == dm_chat_id => Some(InlineEvent::Reaction {
            message_id: message_id.get(),
            user_id: user_id.get(),
            emoji: reaction.clone(),
            removed: *removed,
        }),
        ClientEvent::MessageActionInvoked {
            interaction_id,
            chat_id,
            message_id,
            actor_user_id,
            data,
            ..
        } if *chat_id == dm_chat_id => Some(InlineEvent::Action {
            interaction_id: interaction_id.get(),
            message_id: message_id.get(),
            actor_id: actor_user_id.get(),
            data: data.clone(),
        }),
        _ => None,
    }
}

/// Builds the Dots client for a Codex executable.
pub(crate) fn dots_client(codex: &Path) -> Result<DotsClient, inline_dots::DotsError> {
    DotsClient::new(
        DotsConfig::default(),
        Arc::new(CodexAppServerTokenSource::new(codex)),
    )
}

/// Checks the Codex login and finds the Dot; used by setup and doctor.
pub(crate) async fn preflight(codex: &Path) -> Result<inline_dots::DotRoom, String> {
    let client = dots_client(codex).map_err(|error| error.to_string())?;
    inline_dots::discover(&client)
        .await
        .map_err(|error| error.to_string())
}

pub(crate) struct DotsLaunch<'a> {
    pub(crate) installation: &'a ProviderInstallationConfig,
    pub(crate) owner_user_id: i64,
    pub(crate) dm_chat_id: InlineId,
    pub(crate) bot: InlineClient,
    pub(crate) bot_store: SqliteStore,
    pub(crate) inline_events: LosslessEventReceiver,
    pub(crate) connection_lease: &'a ProviderConnectionLease,
    pub(crate) readiness: Option<&'a ProviderReadiness>,
    pub(crate) external_shutdown: Option<tokio::sync::watch::Receiver<bool>>,
    pub(crate) standalone_runtime: bool,
    pub(crate) profile: Option<ProfileSync>,
    pub(crate) owner_control: Option<Arc<super::owner_control::OwnerControl>>,
}

/// Serves the Dots relay until shutdown.
pub(crate) async fn run_dots_relay(
    launch: DotsLaunch<'_>,
) -> Result<(), Box<dyn std::error::Error>> {
    let DotsLaunch {
        installation,
        owner_user_id,
        dm_chat_id,
        bot,
        bot_store,
        mut inline_events,
        connection_lease,
        readiness,
        mut external_shutdown,
        standalone_runtime,
        profile,
        owner_control,
    } = launch;
    // Typing is best-effort and only on the broadcast stream.
    let mut best_effort = bot.subscribe();
    let client = dots_client(&installation.executable)?;
    let connector = Arc::new(DotsConnector::new(client, ConnectorSettings::default()));
    let store = Arc::new(RelayStore::open(
        &installation.state_dir.join("dots-relay.sqlite"),
    )?);
    let side = Arc::new(BotDm::new(
        bot.clone(),
        bot_store.clone(),
        dm_chat_id,
        profile,
        owner_control,
    )?);
    let relay = Arc::new(Relay::new(
        connector,
        side,
        store,
        RelayConfig {
            owner_user_id,
            agent_name: "Dot".into(),
            network_name: "ChatGPT".into(),
            request_salt: format!("bot-{}", installation.bot_user_id),
            mirror_owner_default: true,
        },
    ));
    relay.recover().await?;

    let (stop, stopped) = tokio::sync::watch::channel(false);
    let mut remote = {
        let relay = relay.clone();
        tokio::spawn(async move { relay.run_remote(stopped).await })
    };
    let mut health = relay.health();
    let installation_id = installation.installation_id.clone();
    let report = |health: &RelayHealth| {
        let Some(readiness) = readiness else { return };
        match &health.connector {
            Some(inline_relay::ConnectorHealth::NeedsLogin(detail)) => {
                readiness.mark_needs_setup(&installation_id, &format!("ChatGPT: {detail}"))
            }
            Some(inline_relay::ConnectorHealth::Degraded(detail)) => {
                readiness.mark_restarting_with_detail(&installation_id, detail)
            }
            Some(inline_relay::ConnectorHealth::Ready) => readiness.mark_ready(&installation_id),
            None => readiness.mark_restarting(&installation_id),
        }
    };
    report(&health.borrow());
    eprintln!(
        "ChatGPT Dots bridge ready for @{}.",
        installation.bot_username
    );

    let mut remote_delay = Duration::from_secs(3);
    let result: Result<(), Box<dyn std::error::Error>> = loop {
        tokio::select! {
            _ = super::wait_for_standalone_termination(standalone_runtime) => break Ok(()),
            _ = super::setup::wait_for_control_shutdown(&mut external_shutdown) => break Ok(()),
            outcome = &mut remote => {
                match outcome {
                    Ok(Ok(())) => log::warn!(target: "inline::bridge::dots", "remote worker ended unexpectedly"),
                    Ok(Err(error)) => log::warn!(target: "inline::bridge::dots", "remote worker failed: {error}"),
                    Err(error) => log::warn!(target: "inline::bridge::dots", "remote worker task failed: {error}"),
                }
                relay.set_connector_health(inline_relay::ConnectorHealth::Degraded("remote worker stopped; reconnecting".into()));
                report(&health.borrow());
                let relay = relay.clone();
                let mut stopped = stop.subscribe();
                let delay = remote_delay;
                remote = tokio::spawn(async move {
                    tokio::select! {
                        _ = tokio::time::sleep(delay) => {}
                        _ = stopped.changed() => return Ok(()),
                    }
                    relay.run_remote(stopped).await
                });
                remote_delay = (remote_delay * 2).min(Duration::from_secs(60));
            }
            changed = health.changed() => {
                if changed.is_ok() {
                    if matches!(health.borrow().connector, Some(inline_relay::ConnectorHealth::Ready)) {
                        remote_delay = Duration::from_secs(3);
                    }
                    report(&health.borrow());
                }
            }
            event = best_effort.recv() => {
                if let Ok(event @ ClientEvent::Typing { .. }) = event
                    && let Some(event) = relay_event(&event, dm_chat_id)
                    && let Err(error) = relay.handle_inline(event).await
                {
                    log::debug!(target: "inline::bridge::dots", "typing not applied: {error}");
                }
            }
            delivery = inline_events.recv_delivery() => {
                let Some(delivery) = delivery else {
                    break Err(io::Error::other("Inline event stream ended").into());
                };
                connection_lease.observe(delivery.event(), &bot);
                let event = match guest_candidate(delivery.event(), dm_chat_id, owner_user_id) {
                    Some(candidate) => admit_guest(&bot, &bot_store, candidate).await,
                    None => relay_event(delivery.event(), dm_chat_id),
                };
                if let Some(event) = event
                    && let Err(error) = relay.handle_inline(event).await
                {
                    // Unacknowledged deliveries come back; a store or Inline
                    // failure is retried rather than dropped.
                    log::warn!(target: "inline::bridge::dots", "inline event not applied: {error}");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
                if let Err(error) = delivery.ack().await { break Err(error.into()); }
            }
        }
    };
    let _ = stop.send(true);
    match tokio::time::timeout(Duration::from_secs(10), &mut remote).await {
        Ok(Ok(Err(error))) => log::warn!(target: "inline::bridge::dots", "relay stopped: {error}"),
        Ok(Err(error)) => log::warn!(target: "inline::bridge::dots", "relay task failed: {error}"),
        Err(_) => {
            remote.abort();
            let _ = remote.await;
        }
        _ => {}
    }
    bot.shutdown().await?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_client::{MessageMetadata, MessageRecord};

    fn stored(chat: i64, outgoing: bool, content: MessageContent, edited: bool) -> ClientEvent {
        ClientEvent::MessageStored {
            message: MessageRecord {
                chat_id: InlineId::new(chat),
                message_id: InlineId::new(9),
                sender_id: InlineId::new(100),
                timestamp: 1,
                is_outgoing: outgoing,
                content,
                reply_to_message_id: Some(InlineId::new(3)),
                metadata: MessageMetadata {
                    edit_timestamp: edited.then_some(2),
                    ..Default::default()
                },
                transaction: None,
            },
        }
    }

    #[test]
    fn only_owner_dm_messages_reach_the_relay() {
        let dm = InlineId::new(42);
        let text = MessageContent::Text { text: "hi".into() };
        assert_eq!(
            relay_event(&stored(42, false, text.clone(), false), dm),
            Some(InlineEvent::Message {
                message_id: 9,
                sender_id: 100,
                text: "hi".into(),
                reply_to: Some(3),
                media: None,
                edited: false,
            })
        );
        assert_eq!(
            relay_event(&stored(43, false, text.clone(), false), dm),
            None
        );
        assert_eq!(
            relay_event(&stored(42, true, text.clone(), false), dm),
            None
        );
        assert!(matches!(
            relay_event(&stored(42, false, text, true), dm),
            Some(InlineEvent::Message { message_id: 9, .. })
        ));
    }

    #[test]
    fn media_keeps_caption_and_link() {
        let media = MessageContent::Media {
            kind: MediaKind::Photo,
            file_id: "f".into(),
            url: Some("https://cdn.inline.chat/f".into()),
            mime_type: Some("image/png".into()),
            file_name: Some("a.png".into()),
            caption: Some("look".into()),
            size_bytes: Some(5),
            width: None,
            height: None,
            duration_ms: None,
        };
        let Some(InlineEvent::Message { text, media, .. }) =
            relay_event(&stored(42, false, media, false), InlineId::new(42))
        else {
            panic!("expected a message");
        };
        assert_eq!(text, "look");
        assert_eq!(
            media.unwrap().url.as_deref(),
            Some("https://cdn.inline.chat/f")
        );
    }

    #[test]
    fn reactions_and_clicks_are_scoped_to_the_dm() {
        let dm = InlineId::new(42);
        let reaction = ClientEvent::ReactionChanged {
            chat_id: InlineId::new(41),
            message_id: InlineId::new(1),
            user_id: InlineId::new(100),
            reaction: "👍".into(),
            removed: false,
        };
        assert_eq!(relay_event(&reaction, dm), None);
    }

    #[test]
    fn dots_provider_is_registered() {
        let asset = super::super::provider::provider_profile_asset(DOTS_PROVIDER_ID).unwrap();
        super::super::provider::validate_provider_profile_asset(asset).unwrap();
        assert_eq!(
            super::super::provider::provider_display_name(DOTS_PROVIDER_ID),
            Some(DOTS_DISPLAY_NAME)
        );
        let commands: Vec<_> = super::super::setup::agent_command_catalog(DOTS_PROVIDER_ID)
            .into_iter()
            .map(|command| command.command)
            .collect();
        assert_eq!(commands, ["help", "status", "mirror", "share"]);
    }

    #[test]
    fn deletes_typing_and_unknown_content_are_mapped() {
        let dm = InlineId::new(42);
        assert_eq!(
            relay_event(
                &ClientEvent::MessageDeleted {
                    chat_id: dm,
                    message_id: InlineId::new(5)
                },
                dm
            ),
            Some(InlineEvent::Deleted { message_id: 5 })
        );
        assert_eq!(
            relay_event(
                &ClientEvent::Typing {
                    chat_id: dm,
                    user_id: InlineId::new(100),
                    is_typing: true
                },
                dm
            ),
            Some(InlineEvent::Typing {
                user_id: 100,
                active: true
            })
        );
        let unsupported = MessageContent::Unsupported {
            reason: "poll".into(),
        };
        assert_eq!(
            relay_event(&stored(42, false, unsupported, false), dm),
            Some(InlineEvent::Unsupported {
                message_id: 9,
                sender_id: 100
            })
        );
    }

    fn entity(
        kind: &str,
        offset: i64,
        length: i64,
        value: Option<&str>,
    ) -> inline_client::MessageEntityRecord {
        inline_client::MessageEntityRecord {
            kind: kind.into(),
            offset,
            length,
            user_id: None,
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: value.map(str::to_owned),
        }
    }

    #[test]
    fn guests_are_other_people_writing_outside_the_owner_dm() {
        let dm = InlineId::new(42);
        let text = MessageContent::Text { text: "hi".into() };
        let candidate = guest_candidate(&stored(43, false, text.clone(), false), dm, 1).unwrap();
        assert_eq!(
            (
                candidate.chat_id,
                candidate.message_id,
                candidate.sender_id,
                candidate.mentioned,
                candidate.text.as_str()
            ),
            (43, 9, 100, false, "hi")
        );
        assert!(guest_candidate(&stored(42, false, text.clone(), false), dm, 1).is_none());
        assert!(guest_candidate(&stored(43, true, text.clone(), false), dm, 1).is_none());
        // The owner's own messages elsewhere are not guest requests.
        assert!(guest_candidate(&stored(43, false, text, false), dm, 100).is_none());
    }

    #[test]
    fn share_commands_name_users_by_mention_or_id() {
        let mention = inline_client::MessageEntityRecord {
            user_id: Some(InlineId::new(12)),
            ..entity("TYPE_MENTION", 7, 6, None)
        };
        let text = entities_to_markdown("/share @alice", std::slice::from_ref(&mention));
        assert_eq!(text, "/share [@alice](inline://user?id=12)");
        assert_eq!(
            command_user_ids("[@alice](inline://user?id=12) 7"),
            vec![7, 12]
        );
        assert!(command_user_ids("remove").is_empty());
        // Ordinary messages keep mentions as plain text.
        assert_eq!(
            entities_to_markdown("hi @alice", &[entity("TYPE_MENTION", 3, 6, None)]),
            "hi @alice"
        );
    }

    #[test]
    fn inline_formatting_reaches_the_agent_as_markdown() {
        let text = "see docs and run ls now";
        let entities = [
            entity("TYPE_TEXT_URL", 4, 4, Some("https://example.com/docs")),
            entity("TYPE_CODE", 17, 2, None),
            entity("TYPE_BOLD", 0, 3, None),
        ];
        assert_eq!(
            entities_to_markdown(text, &entities),
            "**see** [docs](https://example.com/docs) and run `ls` now"
        );
        // UTF-16 offsets past an emoji, and a nested bold link.
        let text = "👋 hi there";
        let entities = [
            entity("TYPE_BOLD", 3, 8, None),
            entity("TYPE_TEXT_URL", 6, 5, Some("https://x.y")),
        ];
        assert_eq!(
            entities_to_markdown(text, &entities),
            "👋 **hi [there](https://x.y)**"
        );
        assert_eq!(entities_to_markdown("plain", &[]), "plain");
        assert_eq!(
            entities_to_markdown("@sam hi", &[entity("TYPE_MENTION", 0, 4, None)]),
            "@sam hi"
        );
    }

    #[test]
    fn images_upload_as_photos() {
        assert_eq!(media_kind("image/png; charset=binary"), MediaKind::Photo);
        assert_eq!(media_kind("image/png"), MediaKind::Photo);
        assert_eq!(media_kind("application/pdf"), MediaKind::Document);
    }
}

#[cfg(test)]
mod packaging_tests {
    // Evaluate the globs used by these context filters, including directory
    // exclusions and ordered negation. No Docker daemon is needed.
    fn included(path: &str, rules: &str) -> bool {
        let mut included = true;
        for line in rules
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
        {
            let (allow, pattern) = line.strip_prefix('!').map_or((false, line), |p| (true, p));
            let pattern = pattern.trim_matches('/');
            let mut regex = String::from("^");
            if !pattern.contains('/') && pattern != "**" {
                regex.push_str("(?:.*/)?");
            }
            let mut chars = pattern.chars().peekable();
            while let Some(c) = chars.next() {
                match c {
                    '*' if chars.peek() == Some(&'*') => {
                        chars.next();
                        if chars.peek() == Some(&'/') {
                            chars.next();
                            regex.push_str("(?:.*/)?");
                        } else {
                            regex.push_str(".*");
                        }
                    }
                    '*' => regex.push_str("[^/]*"),
                    '?' => regex.push_str("[^/]"),
                    c => regex.push_str(&regex::escape(&c.to_string())),
                }
            }
            regex.push_str("(?:/.*)?$");
            if regex::Regex::new(&regex).unwrap().is_match(path) {
                included = allow;
            }
        }
        included
    }

    #[test]
    fn dots_docker_context_keeps_rust_inputs_and_excludes_local_artifacts() {
        let rules = include_str!("../../packaging/dots/Dockerfile.dockerignore");
        let root_rules = include_str!("../../../.dockerignore");
        assert!(
            !included("cli/Cargo.toml", root_rules),
            "the root filter excludes the CLI"
        );
        for path in [
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "cli/Cargo.toml",
            "cli/build.rs",
            "cli/src/main.rs",
            "cli/assets/provider-avatars/dots.png",
            "cli/packaging/dots/entrypoint.sh",
            "cli/src/bridge/adapter_locks/amp/dist/index.js",
            "crates/dots/src/client.rs",
            "crates/relay/src/store.rs",
            "vendor/agent-client-protocol/Cargo.toml",
            "proto/core.proto",
            "skills/inline/SKILL.md",
            "skills/inline/agents/openai.yaml",
            "skills/inline/references/inline-cli.md",
        ] {
            assert!(
                included(path, rules),
                "required build input excluded: {path}"
            );
        }
        for path in [
            "target/debug/inline",
            "cli/target/debug/inline",
            "cli/node_modules/package/index.js",
            ".git/config",
            "cli/.env",
            "crates/relay/state.sqlite",
            "cli/debug.log",
        ] {
            assert!(!included(path, rules), "local artifact included: {path}");
        }
    }
}
