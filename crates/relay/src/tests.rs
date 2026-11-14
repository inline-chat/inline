//! Engine tests against in-memory fakes of both sides.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use crate::*;

const OWNER: i64 = 100;

#[derive(Default)]
struct FakeInline {
    fail_next_post: Mutex<bool>,
    fail_next_file_post: Mutex<bool>,
    fail_next_edit: Mutex<bool>,
    fail_next_reaction: Mutex<bool>,
    fail_next_button_post: Mutex<bool>,
    fail_post_count: Mutex<u32>,
    next_id: Mutex<i64>,
    posts: Mutex<Vec<(i64, InlinePost)>>,
    edits: Mutex<Vec<(i64, String, usize)>>,
    reactions: Mutex<Vec<(i64, String, bool)>>,
    typing: Mutex<Vec<bool>>,
    toasts: Mutex<Vec<String>>,
    reads: Mutex<Vec<i64>>,
    profiles: Mutex<Vec<(Option<String>, Option<usize>)>>,
    owner_edits: Mutex<Vec<(i64, String)>>,
    owner_reactions: Mutex<Vec<(i64, String, bool)>>,
    guest_posts: Mutex<Vec<(i64, i64, InlinePost)>>,
    guest_edits: Mutex<Vec<(i64, i64, String)>>,
}

impl FakeInline {
    fn posts(&self) -> Vec<(i64, InlinePost)> {
        self.posts.lock().unwrap().clone()
    }
    fn texts(&self) -> Vec<String> {
        self.posts()
            .into_iter()
            .map(|(_, post)| post.text)
            .collect()
    }
}

impl InlineSide for FakeInline {
    fn post<'a>(&'a self, post: &'a InlinePost) -> BoxFuture<'a, InlineResult<i64>> {
        Box::pin(async move {
            {
                let mut failures = self.fail_post_count.lock().unwrap();
                if *failures > 0 {
                    *failures -= 1;
                    return Err(InlineError("bad message".into()));
                }
            }
            if (!post.buttons.is_empty()
                && std::mem::take(&mut *self.fail_next_button_post.lock().unwrap()))
                || std::mem::take(&mut *self.fail_next_post.lock().unwrap())
                || (post.file.is_some()
                    && std::mem::take(&mut *self.fail_next_file_post.lock().unwrap()))
            {
                return Err(InlineError("temporary Inline outage".into()));
            }
            let mut next = self.next_id.lock().unwrap();
            *next += 1;
            let id = 1000 + *next;
            self.posts.lock().unwrap().push((id, post.clone()));
            Ok(id)
        })
    }
    fn edit<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
        buttons: Option<&'a [Vec<Button>]>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            if std::mem::take(&mut *self.fail_next_edit.lock().unwrap()) {
                return Err(InlineError("temporary Inline outage".into()));
            }
            self.edits.lock().unwrap().push((
                message_id,
                text.to_owned(),
                buttons.map_or(usize::MAX, <[_]>::len),
            ));
            Ok(())
        })
    }
    fn react<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            if std::mem::take(&mut *self.fail_next_reaction.lock().unwrap()) {
                return Err(InlineError("temporary Inline outage".into()));
            }
            self.reactions
                .lock()
                .unwrap()
                .push((message_id, emoji.to_owned(), remove));
            Ok(())
        })
    }
    fn edit_as_owner<'a>(
        &'a self,
        message_id: i64,
        text: &'a str,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.owner_edits
                .lock()
                .unwrap()
                .push((message_id, text.to_owned()));
            Ok(())
        })
    }
    fn react_as_owner<'a>(
        &'a self,
        message_id: i64,
        emoji: &'a str,
        remove: bool,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.owner_reactions
                .lock()
                .unwrap()
                .push((message_id, emoji.to_owned(), remove));
            Ok(())
        })
    }
    fn typing(&self, active: bool) -> BoxFuture<'_, InlineResult<()>> {
        Box::pin(async move {
            self.typing.lock().unwrap().push(active);
            Ok(())
        })
    }
    fn answer_action<'a>(
        &'a self,
        _interaction_id: i64,
        toast: Option<&'a str>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.toasts
                .lock()
                .unwrap()
                .push(toast.unwrap_or_default().to_owned());
            Ok(())
        })
    }
    fn mark_read(&self, message_id: i64) -> BoxFuture<'_, InlineResult<()>> {
        Box::pin(async move {
            self.reads.lock().unwrap().push(message_id);
            Ok(())
        })
    }
    fn update_profile<'a>(
        &'a self,
        name: Option<&'a str>,
        avatar: Option<&'a FileData>,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.profiles
                .lock()
                .unwrap()
                .push((name.map(str::to_owned), avatar.map(|a| a.bytes.len())));
            Ok(())
        })
    }
    fn fetch_media<'a>(
        &'a self,
        media: &'a InlineMedia,
        _limit: usize,
    ) -> BoxFuture<'a, InlineResult<FileData>> {
        Box::pin(async move {
            Ok(FileData {
                name: media.name.clone().unwrap_or_default(),
                mime: "image/png".into(),
                bytes: vec![1, 2, 3],
            })
        })
    }
    fn post_in<'a>(
        &'a self,
        chat_id: i64,
        post: &'a InlinePost,
    ) -> BoxFuture<'a, InlineResult<i64>> {
        Box::pin(async move {
            let mut next = self.next_id.lock().unwrap();
            *next += 1;
            let id = 1000 + *next;
            self.guest_posts
                .lock()
                .unwrap()
                .push((chat_id, id, post.clone()));
            Ok(id)
        })
    }
    fn edit_in<'a>(
        &'a self,
        chat_id: i64,
        message_id: i64,
        text: &'a str,
    ) -> BoxFuture<'a, InlineResult<()>> {
        Box::pin(async move {
            self.guest_edits
                .lock()
                .unwrap()
                .push((chat_id, message_id, text.to_owned()));
            Ok(())
        })
    }
    fn command<'a>(
        &'a self,
        name: &'a str,
        arguments: &'a str,
    ) -> BoxFuture<'a, InlineResult<Option<String>>> {
        Box::pin(async move { Ok((name == "share").then(|| format!("shared with {arguments}"))) })
    }
}

#[derive(Default)]
struct FakeConnector {
    run_messages: Mutex<Vec<RemoteMessage>>,
    sends: Mutex<Vec<OutboundMessage>>,
    send_results: Mutex<VecDeque<ConnectorResult<String>>>,
    find_results: Mutex<VecDeque<ConnectorResult<Option<String>>>>,
    finds: Mutex<usize>,
    reactions: Mutex<Vec<(String, Option<String>)>>,
    answers: Mutex<Vec<(String, String, bool)>>,
    file_failures: Mutex<u32>,
    typing: Mutex<u32>,
    read_marks: Mutex<Vec<String>>,
}

impl Connector for FakeConnector {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            reactions: true,
            send_files: true,
            max_file_bytes: 1024,
            edits: false,
        }
    }
    fn run<'a>(
        &'a self,
        _checkpoint: Option<String>,
        _events: tokio::sync::mpsc::Sender<ConnectorEvent>,
    ) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(async move {
            let messages = self.run_messages.lock().unwrap().clone();
            _events
                .send(ConnectorEvent::Health(ConnectorHealth::Ready))
                .await
                .unwrap();
            for message in messages {
                _events
                    .send(ConnectorEvent::Message(message))
                    .await
                    .unwrap();
            }
            _events.closed().await;
            Ok(())
        })
    }
    fn send<'a>(&'a self, message: &'a OutboundMessage) -> BoxFuture<'a, ConnectorResult<String>> {
        Box::pin(async move {
            let count = {
                let mut sends = self.sends.lock().unwrap();
                sends.push(message.clone());
                sends.len()
            };
            self.send_results
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| Ok(format!("remote-sent-{count}")))
        })
    }
    fn find_sent<'a>(
        &'a self,
        _request_id: &'a str,
        _reply_to: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<Option<String>>> {
        Box::pin(async move {
            *self.finds.lock().unwrap() += 1;
            self.find_results
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(Ok(None))
        })
    }
    fn set_reaction<'a>(
        &'a self,
        message_id: &'a str,
        emoji: Option<&'a str>,
    ) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(async move {
            self.reactions
                .lock()
                .unwrap()
                .push((message_id.to_owned(), emoji.map(str::to_owned)));
            Ok(())
        })
    }
    fn fetch_file<'a>(
        &'a self,
        _message_id: &'a str,
        file: &'a RemoteFile,
    ) -> BoxFuture<'a, ConnectorResult<Option<FileData>>> {
        Box::pin(async move {
            {
                let mut failures = self.file_failures.lock().unwrap();
                if *failures > 0 {
                    *failures -= 1;
                    return Err(ConnectorError::new(FailureKind::Transient, "storage 503"));
                }
            }
            Ok((file.locator != "gone").then(|| FileData {
                name: file.name.clone().unwrap_or_default(),
                mime: "image/png".into(),
                bytes: vec![9],
            }))
        })
    }
    fn answer_confirmation<'a>(
        &'a self,
        message_id: &'a str,
        key: &'a str,
        accept: bool,
    ) -> BoxFuture<'a, ConnectorResult<ConfirmationAnswer>> {
        Box::pin(async move {
            self.answers
                .lock()
                .unwrap()
                .push((message_id.to_owned(), key.to_owned(), accept));
            Ok(ConfirmationAnswer::Applied)
        })
    }
    fn describe(&self) -> BoxFuture<'_, String> {
        Box::pin(async { "Dot: Test".to_owned() })
    }
    fn owner_typing(&self) -> BoxFuture<'_, ConnectorResult<()>> {
        Box::pin(async move {
            *self.typing.lock().unwrap() += 1;
            Ok(())
        })
    }
    fn mark_read<'a>(&'a self, message_id: &'a str) -> BoxFuture<'a, ConnectorResult<()>> {
        Box::pin(async move {
            self.read_marks.lock().unwrap().push(message_id.to_owned());
            Ok(())
        })
    }
    fn fetch_avatar<'a>(
        &'a self,
        _locator: &'a str,
    ) -> BoxFuture<'a, ConnectorResult<Option<FileData>>> {
        Box::pin(async {
            Ok(Some(FileData {
                name: "avatar.png".into(),
                mime: "image/png".into(),
                bytes: vec![0; 4],
            }))
        })
    }
}

struct Harness {
    relay: Relay,
    inline: Arc<FakeInline>,
    connector: Arc<FakeConnector>,
    store: Arc<RelayStore>,
}

fn harness() -> Harness {
    let inline = Arc::new(FakeInline::default());
    let connector = Arc::new(FakeConnector::default());
    let store = Arc::new(RelayStore::open_in_memory().unwrap());
    let relay = Relay::new(
        connector.clone(),
        inline.clone(),
        store.clone(),
        RelayConfig {
            owner_user_id: OWNER,
            agent_name: "Dot".into(),
            network_name: "ChatGPT".into(),
            request_salt: "bot-1".into(),
            mirror_owner_default: true,
        },
    );
    Harness {
        relay,
        inline,
        connector,
        store,
    }
}

fn agent(id: &str, text: &str, revision: &str) -> RemoteMessage {
    RemoteMessage {
        id: id.into(),
        speaker: Speaker::Agent,
        client_request_id: None,
        text: text.into(),
        files: Vec::new(),
        reply_to: None,
        deleted: false,
        agent_reaction: None,
        owner_reaction: None,
        task_id: None,
        confirmation: None,
        revision: revision.into(),
    }
}

fn owner_text(message_id: i64, text: &str) -> InlineEvent {
    InlineEvent::Message {
        message_id,
        sender_id: OWNER,
        text: text.into(),
        reply_to: None,
        media: None,
        edited: false,
    }
}

#[tokio::test]
async fn agent_message_posts_once_and_edits_on_change() {
    let h = harness();
    let message = agent("m1", "hello", "r1");
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    assert_eq!(h.inline.texts(), vec!["hello"]);
    let edited = RemoteMessage {
        text: "hello again".into(),
        revision: "r2".into(),
        ..message
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(edited))
        .await
        .unwrap();
    let edits = h.inline.edits.lock().unwrap().clone();
    assert_eq!(edits.len(), 1);
    assert_eq!(edits[0].1, "hello again");
    assert_eq!(h.inline.posts().len(), 1);
}

#[tokio::test]
async fn deleted_remote_message_is_replaced() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "x", "r1")))
        .await
        .unwrap();
    let mut deleted = agent("m1", "", "r2");
    deleted.deleted = true;
    h.relay
        .handle_remote(ConnectorEvent::Message(deleted))
        .await
        .unwrap();
    assert_eq!(h.inline.edits.lock().unwrap()[0].1, "_Deleted in ChatGPT._");
}

#[tokio::test]
async fn owner_message_is_sent_once_and_echo_is_not_mirrored() {
    let h = harness();
    h.relay
        .handle_inline(owner_text(7, "hi Dot"))
        .await
        .unwrap();
    // Redelivery of the same Inline event.
    h.relay
        .handle_inline(owner_text(7, "hi Dot"))
        .await
        .unwrap();
    let sends = h.connector.sends.lock().unwrap().clone();
    assert_eq!(sends.len(), 1);
    assert_eq!(sends[0].text, "hi Dot");
    assert_eq!(sends[0].request_id, correlation_id("bot-1", 7));

    // The remote echo of the same message must not be mirrored back.
    let echo = RemoteMessage {
        speaker: Speaker::Owner,
        client_request_id: Some(sends[0].request_id.clone()),
        ..agent("remote-sent-1", "hi Dot", "e1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(echo.clone()))
        .await
        .unwrap();
    assert!(h.inline.posts().is_empty());

    // The Dot reacts to the owner's message: the bot reacts in Inline.
    let reacted = RemoteMessage {
        agent_reaction: Some("👍".into()),
        ..echo
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(reacted))
        .await
        .unwrap();
    assert_eq!(
        h.inline.reactions.lock().unwrap().clone(),
        vec![(7, "👍".to_owned(), false)]
    );
}

#[tokio::test]
async fn replies_map_both_ways() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "question?", "r1")))
        .await
        .unwrap();
    let inline_id = h.inline.posts()[0].0;
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 8,
            sender_id: OWNER,
            text: "answer".into(),
            reply_to: Some(inline_id),
            media: None,
            edited: false,
        })
        .await
        .unwrap();
    assert_eq!(
        h.connector.sends.lock().unwrap()[0].reply_to.as_deref(),
        Some("m1")
    );
    let mut reply = agent("m2", "thanks", "r1");
    reply.reply_to = Some("remote-sent-1".into());
    h.relay
        .handle_remote(ConnectorEvent::Message(reply))
        .await
        .unwrap();
    assert_eq!(h.inline.posts()[1].1.reply_to, Some(8));
}

#[tokio::test]
async fn uncertain_send_is_reconciled_before_resending() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(
            FailureKind::Uncertain,
            "timed out",
        )));
    h.relay
        .handle_inline(owner_text(9, "important"))
        .await
        .unwrap();
    assert_eq!(h.store.pending_sends().unwrap().len(), 1);
    assert!(
        h.inline.texts()[0].starts_with("Not delivered yet"),
        "owner is told once"
    );
    // The earlier attempt landed after all.
    h.connector
        .find_results
        .lock()
        .unwrap()
        .push_back(Ok(Some("m-late".into())));
    h.store
        .defer_send(&correlation_id("bot-1", 9), 1, 0)
        .unwrap();
    h.relay.retry_pending().await.unwrap();
    assert_eq!(h.connector.sends.lock().unwrap().len(), 1, "no second send");
    assert!(h.store.pending_sends().unwrap().is_empty());
    assert_eq!(h.store.inline_for_remote("m-late").unwrap(), Some(9));
}

#[tokio::test]
async fn retry_resends_with_same_request_id_when_not_found() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(FailureKind::Transient, "503")));
    h.relay.handle_inline(owner_text(9, "again")).await.unwrap();
    h.store
        .defer_send(&correlation_id("bot-1", 9), 1, 0)
        .unwrap();
    h.relay.retry_pending().await.unwrap();
    let sends = h.connector.sends.lock().unwrap().clone();
    assert_eq!(sends.len(), 2);
    assert_eq!(sends[0].request_id, sends[1].request_id);
    assert_eq!(*h.connector.finds.lock().unwrap(), 1);
    assert!(h.store.pending_sends().unwrap().is_empty());
}

#[tokio::test]
async fn rejected_send_tells_the_owner() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(FailureKind::Rejected, "too long")));
    h.relay.handle_inline(owner_text(9, "x")).await.unwrap();
    assert!(h.store.pending_sends().unwrap().is_empty());
    let posts = h.inline.posts();
    assert_eq!(posts[0].1.reply_to, Some(9));
    assert!(posts[0].1.text.contains("too long"));
}

#[tokio::test]
async fn non_owner_input_is_ignored() {
    let h = harness();
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 5,
            sender_id: 999,
            text: "let me in".into(),
            reply_to: None,
            media: None,
            edited: false,
        })
        .await
        .unwrap();
    assert!(h.connector.sends.lock().unwrap().is_empty());
    assert!(h.inline.posts().is_empty());
}

#[tokio::test]
async fn owner_typed_in_remote_app_is_mirrored_until_turned_off() {
    let h = harness();
    let typed = RemoteMessage {
        speaker: Speaker::Owner,
        ..agent("o1", "from my phone", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(typed))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts[0].1.text, "from my phone");
    assert!(
        posts[0].1.as_owner,
        "typed in ChatGPT shows as the owner's own message"
    );
    h.relay
        .handle_inline(owner_text(3, "/mirror off"))
        .await
        .unwrap();
    let typed = RemoteMessage {
        speaker: Speaker::Owner,
        ..agent("o2", "quiet", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(typed))
        .await
        .unwrap();
    assert_eq!(
        h.inline.posts().len(),
        2,
        "mirror post plus the command reply"
    );
    assert!(
        h.connector.sends.lock().unwrap().is_empty(),
        "commands stay local"
    );
}

#[tokio::test]
async fn owner_reactions_forward_and_remove_only_matching() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "hi", "r1")))
        .await
        .unwrap();
    let inline_id = h.inline.posts()[0].0;
    let react = |emoji: &str, removed| InlineEvent::Reaction {
        message_id: inline_id,
        user_id: OWNER,
        emoji: emoji.into(),
        removed,
    };
    h.relay.handle_inline(react("👍", false)).await.unwrap();
    h.relay.handle_inline(react("❤️", false)).await.unwrap();
    h.relay.handle_inline(react("👍", true)).await.unwrap();
    h.relay.handle_inline(react("❤️", true)).await.unwrap();
    assert_eq!(
        h.connector.reactions.lock().unwrap().clone(),
        vec![
            ("m1".to_owned(), Some("👍".to_owned())),
            ("m1".to_owned(), Some("❤️".to_owned())),
            ("m1".to_owned(), None),
        ]
    );
}

fn confirmation(status: ConfirmationStatus) -> Confirmation {
    Confirmation {
        key: "def-1".into(),
        title: Some("Send email?".into()),
        message: "Send the draft to Sam".into(),
        fields: vec![("To".into(), "sam@example.com".into())],
        answerable: true,
        status,
    }
}

#[tokio::test]
async fn confirmation_is_answered_once_by_the_owner_only() {
    let h = harness();
    let mut message = agent("m1", "I need your OK", "r1");
    message.confirmation = Some(confirmation(ConfirmationStatus::Pending));
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 2);
    let (card_id, card) = &posts[1];
    assert_eq!(card.reply_to, Some(posts[0].0));
    assert_eq!(card.buttons[0].len(), 2);
    let approve = card.buttons[0][0].data.clone();

    let click = |actor| InlineEvent::Action {
        interaction_id: 1,
        message_id: *card_id,
        actor_id: actor,
        data: approve.clone(),
    };
    h.relay.handle_inline(click(999)).await.unwrap();
    assert!(h.connector.answers.lock().unwrap().is_empty());
    h.relay.handle_inline(click(OWNER)).await.unwrap();
    h.relay.handle_inline(click(OWNER)).await.unwrap();
    assert_eq!(
        h.connector.answers.lock().unwrap().clone(),
        vec![("m1".to_owned(), "def-1".to_owned(), true)]
    );
    let toasts = h.inline.toasts.lock().unwrap().clone();
    assert_eq!(
        toasts,
        vec![
            "Only the bot owner can answer this.",
            "Sending your answer…",
            "This request was already answered."
        ]
    );
    let edits = h.inline.edits.lock().unwrap().clone();
    assert_eq!(edits.last().unwrap().0, *card_id);
    assert!(edits.last().unwrap().1.ends_with("_✅ Approved._"));
    assert_eq!(edits.last().unwrap().2, 0, "buttons removed");
}

#[tokio::test]
async fn confirmation_closed_remotely_updates_card() {
    let h = harness();
    let mut message = agent("m1", "ok?", "r1");
    message.confirmation = Some(confirmation(ConfirmationStatus::Pending));
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    message.revision = "r2".into();
    message.confirmation = Some(confirmation(ConfirmationStatus::Closed("accepted".into())));
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let edits = h.inline.edits.lock().unwrap().clone();
    assert!(
        edits
            .iter()
            .any(|(_, text, buttons)| text.ends_with("_Approved._") && *buttons == 0)
    );
}

#[tokio::test]
async fn unanswerable_confirmation_points_to_remote_app() {
    let h = harness();
    let mut message = agent("m1", "", "r1");
    message.confirmation = Some(Confirmation {
        answerable: false,
        ..confirmation(ConfirmationStatus::Pending)
    });
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].1.buttons.is_empty());
    assert!(posts[0].1.text.ends_with("_Answer this in ChatGPT._"));
}

#[tokio::test]
async fn restart_settles_in_flight_confirmation_answers() {
    let h = harness();
    h.store
        .put_confirmation(&ConfirmationCard {
            key: "k".into(),
            remote_id: "m".into(),
            inline_id: 55,
            state: ConfirmationState::Answering,
            body: "b".into(),
        })
        .unwrap();
    h.relay.recover().await.unwrap();
    assert_eq!(
        h.store.confirmation("k").unwrap().unwrap().state,
        ConfirmationState::Done
    );
    assert_eq!(h.inline.edits.lock().unwrap()[0].0, 55);
}

#[tokio::test]
async fn task_card_is_posted_once_and_edited_in_place() {
    let h = harness();
    let mut message = agent("m1", "On it.", "r1");
    message.task_id = Some("t1".into());
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let anchor = h.inline.posts()[0].0;
    let update = |label: &str| {
        ConnectorEvent::Task(TaskUpdate {
            id: "t1".into(),
            title: Some("Book flights".into()),
            label: label.into(),
            terminal: false,
            entries: Vec::new(),
        })
    };
    h.relay.handle_remote(update("Working…")).await.unwrap();
    h.relay.handle_remote(update("Working…")).await.unwrap();
    h.relay.handle_remote(update("Completed")).await.unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[1].1.reply_to, Some(anchor));
    assert_eq!(
        posts[1].1.text, "🗂 **Task**\nStarting…",
        "posted with its message"
    );
    let edits = h.inline.edits.lock().unwrap().clone();
    let card = posts[1].0;
    assert_eq!(
        edits,
        vec![
            (card, "🗂 **Book flights**\nWorking…".to_owned(), usize::MAX),
            (card, "🗂 **Book flights**\nCompleted".to_owned(), usize::MAX),
        ],
        "unchanged updates do not edit again"
    );
}

#[tokio::test]
async fn files_mirror_and_missing_files_get_a_placeholder() {
    let h = harness();
    let mut message = agent("m1", "", "r1");
    message.files = vec![
        RemoteFile {
            key: "a".into(),
            locator: "f1".into(),
            name: Some("chart.png".into()),
        },
        RemoteFile {
            key: "b".into(),
            locator: "gone".into(),
            name: Some("old.pdf".into()),
        },
    ];
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    // A later snapshot must not post the files again.
    message.revision = "r2".into();
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 2);
    assert!(posts[0].1.file.is_some());
    assert!(posts[1].1.text.contains("old.pdf"));
}

#[tokio::test]
async fn owner_media_is_fetched_and_sent() {
    let h = harness();
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 4,
            sender_id: OWNER,
            text: "look".into(),
            reply_to: None,
            media: Some(InlineMedia {
                url: Some("https://cdn.example/x.png".into()),
                name: Some("x.png".into()),
                mime: Some("image/png".into()),
                size: Some(3),
            }),
            edited: false,
        })
        .await
        .unwrap();
    let sends = h.connector.sends.lock().unwrap().clone();
    assert_eq!(sends[0].file.as_ref().unwrap().bytes, vec![1, 2, 3]);
}

#[tokio::test]
async fn checkpoint_is_persisted() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Checkpoint("{\"c\":1}".into()))
        .await
        .unwrap();
    assert_eq!(
        h.store.kv_get("connector.checkpoint").unwrap().as_deref(),
        Some("{\"c\":1}")
    );
}

#[tokio::test]
async fn help_and_status_stay_local() {
    let h = harness();
    h.relay
        .handle_inline(owner_text(1, "/status"))
        .await
        .unwrap();
    h.relay.handle_inline(owner_text(2, "/help")).await.unwrap();
    h.relay
        .handle_inline(owner_text(3, "/unknown thing"))
        .await
        .unwrap();
    let texts = h.inline.texts();
    assert!(texts[0].contains("Dot: Test"));
    assert!(texts[1].contains("/mirror"));
    assert_eq!(
        h.connector.sends.lock().unwrap().len(),
        1,
        "unknown slash text goes through"
    );
}

#[tokio::test]
async fn system_messages_show_as_silent_notices() {
    let h = harness();
    let notice = RemoteMessage {
        speaker: Speaker::System,
        ..agent("s1", "Pip joined the conversation", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(notice))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts[0].1.text, "_Pip joined the conversation_");
    assert!(posts[0].1.silent);
}

#[tokio::test]
async fn agent_read_receipts_mark_the_dm_read_forward_only() {
    let h = harness();
    h.relay.handle_inline(owner_text(7, "one")).await.unwrap();
    h.relay.handle_inline(owner_text(8, "two")).await.unwrap();
    for remote in ["remote-sent-2", "remote-sent-1", "unknown"] {
        h.relay
            .handle_remote(ConnectorEvent::ReadUpTo(remote.into()))
            .await
            .unwrap();
    }
    assert_eq!(h.inline.reads.lock().unwrap().clone(), vec![8]);
}

#[tokio::test]
async fn sending_marks_the_remote_read_and_typing_is_throttled() {
    let h = harness();
    h.relay.handle_inline(owner_text(7, "hi")).await.unwrap();
    assert_eq!(
        h.connector.read_marks.lock().unwrap().clone(),
        vec!["remote-sent-1"]
    );
    for _ in 0..3 {
        h.relay
            .handle_inline(InlineEvent::Typing {
                user_id: OWNER,
                active: true,
            })
            .await
            .unwrap();
    }
    h.relay
        .handle_inline(InlineEvent::Typing {
            user_id: 999,
            active: true,
        })
        .await
        .unwrap();
    assert_eq!(*h.connector.typing.lock().unwrap(), 1);
}

#[tokio::test]
async fn profile_changes_update_the_bot_once() {
    let h = harness();
    let profile = |name: &str, avatar: &str| {
        ConnectorEvent::Profile(AgentProfile {
            name: name.into(),
            avatar: Some(avatar.into()),
        })
    };
    h.relay.handle_remote(profile("Pip", "a1")).await.unwrap();
    h.relay.handle_remote(profile("Pip", "a1")).await.unwrap();
    h.relay.handle_remote(profile("Pippa", "a1")).await.unwrap();
    h.relay.handle_remote(profile("Pippa", "a2")).await.unwrap();
    assert_eq!(
        h.inline.profiles.lock().unwrap().clone(),
        vec![
            (Some("Pip".to_owned()), None),
            (None, Some(4)),
            (Some("Pippa".to_owned()), None),
            (None, Some(4)),
        ]
    );
}

#[tokio::test]
async fn inline_edits_and_deletes_of_sent_messages_are_explained() {
    let h = harness();
    h.relay.handle_inline(owner_text(7, "typo")).await.unwrap();
    let edited = InlineEvent::Message {
        message_id: 7,
        sender_id: OWNER,
        text: "fixed".into(),
        reply_to: None,
        media: None,
        edited: true,
    };
    h.relay.handle_inline(edited.clone()).await.unwrap();
    h.relay.handle_inline(edited).await.unwrap();
    h.relay
        .handle_inline(InlineEvent::Deleted { message_id: 7 })
        .await
        .unwrap();
    h.relay
        .handle_inline(InlineEvent::Deleted { message_id: 7 })
        .await
        .unwrap();
    assert_eq!(
        h.connector.sends.lock().unwrap().len(),
        1,
        "edits are never resent"
    );
    let texts = h.inline.texts();
    assert_eq!(texts.len(), 2);
    assert!(texts[0].starts_with("Edits stay in Inline"));
    assert!(texts[1].contains("still in ChatGPT"));
}

#[tokio::test]
async fn message_edited_before_delivery_is_sent_with_final_text() {
    let h = harness();
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 9,
            sender_id: OWNER,
            text: "final".into(),
            reply_to: None,
            media: None,
            edited: true,
        })
        .await
        .unwrap();
    assert_eq!(h.connector.sends.lock().unwrap()[0].text, "final");
}

#[tokio::test]
async fn unsupported_inline_content_is_explained_once() {
    let h = harness();
    for _ in 0..2 {
        h.relay
            .handle_inline(InlineEvent::Unsupported {
                message_id: 3,
                sender_id: OWNER,
            })
            .await
            .unwrap();
    }
    assert_eq!(h.inline.posts().len(), 1);
    assert!(h.inline.texts()[0].contains("can't be sent"));
}

#[tokio::test]
async fn deleted_in_remote_app_is_flagged_on_owner_message() {
    let h = harness();
    h.relay.handle_inline(owner_text(7, "oops")).await.unwrap();
    let deleted = RemoteMessage {
        speaker: Speaker::Owner,
        deleted: true,
        client_request_id: Some(correlation_id("bot-1", 7)),
        ..agent("remote-sent-1", "", "gone")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(deleted))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts[0].1.reply_to, Some(7));
    assert_eq!(posts[0].1.text, "_Deleted in ChatGPT._");
}

#[tokio::test]
async fn failed_file_downloads_retry_before_a_placeholder() {
    let h = harness();
    *h.connector.file_failures.lock().unwrap() = 2;
    let mut message = agent("m1", "", "r1");
    message.files = vec![RemoteFile {
        key: "a".into(),
        locator: "f1".into(),
        name: Some("chart.png".into()),
    }];
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert!(
        h.inline.posts().is_empty(),
        "no placeholder on a transient failure"
    );
    for _ in 0..2 {
        let (key, raw) = h.store.kv_prefix("file_retry").unwrap().remove(0);
        let mut value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        value["next_at"] = 0.into();
        h.store.kv_set(&key, &value.to_string()).unwrap();
        h.relay.retry_pending().await.unwrap();
    }
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].1.file.is_some());
    assert!(h.store.kv_prefix("file_retry").unwrap().is_empty());
}

#[tokio::test]
async fn task_transcript_entries_post_once_under_the_card() {
    let h = harness();
    let update = |entries: Vec<TaskEntry>| {
        ConnectorEvent::Task(TaskUpdate {
            id: "t1".into(),
            title: Some("Plan trip".into()),
            label: "Completed".into(),
            terminal: true,
            entries,
        })
    };
    let prompt = TaskEntry {
        id: "turn-1:prompt".into(),
        speaker: Speaker::Owner,
        text: "Find flights".into(),
    };
    let answer = TaskEntry {
        id: "turn-1:answer".into(),
        speaker: Speaker::Agent,
        text: "Here are three options.".into(),
    };
    h.relay
        .handle_remote(update(vec![prompt.clone()]))
        .await
        .unwrap();
    h.relay
        .handle_remote(update(vec![prompt, answer]))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts.len(), 3);
    let card = posts[0].0;
    assert_eq!(posts[1].1.reply_to, Some(card));
    assert_eq!(posts[1].1.text, "_Task prompt:_\nFind flights");
    assert_eq!(posts[2].1.text, "Here are three options.");
    assert!(!posts[2].1.silent);
}

#[tokio::test(start_paused = true)]
async fn review_remote_worker_survives_temporary_inline_outage() {
    let h = harness();
    *h.inline.fail_next_post.lock().unwrap() = true;
    h.connector
        .run_messages
        .lock()
        .unwrap()
        .push(agent("m1", "reply", "r1"));
    let (stop, stopped) = tokio::sync::watch::channel(false);
    let relay = Arc::new(h.relay);
    let worker = tokio::spawn(async move { relay.run_remote(stopped).await });
    tokio::task::yield_now().await;
    assert!(h.inline.posts().is_empty());
    tokio::time::advance(std::time::Duration::from_secs(4)).await;
    tokio::task::yield_now().await;
    assert_eq!(h.inline.texts(), vec!["reply"]);
    assert!(!worker.is_finished());
    stop.send(true).unwrap();
    worker.await.unwrap().unwrap();
}

#[tokio::test]
async fn review_replay_finishes_file_after_failed_inline_upload() {
    let h = harness();
    let mut message = agent("m1", "Here is the report", "r1");
    message.files.push(RemoteFile {
        key: "a".into(),
        locator: "file-1".into(),
        name: Some("report.png".into()),
    });
    *h.inline.fail_next_file_post.lock().unwrap() = true;
    assert!(
        h.relay
            .handle_remote(ConnectorEvent::Message(message.clone()))
            .await
            .is_err()
    );
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(
        h.inline
            .posts()
            .iter()
            .filter(|(_, post)| post.file.is_some())
            .count(),
        1,
        "replaying the snapshot should finish its missing file"
    );
}

#[tokio::test]
async fn review_failed_edit_is_retried_on_next_snapshot() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "original", "r1")))
        .await
        .unwrap();
    let edited = agent("m1", "corrected", "r2");
    *h.inline.fail_next_edit.lock().unwrap() = true;
    assert!(
        h.relay
            .handle_remote(ConnectorEvent::Message(edited.clone()))
            .await
            .is_err()
    );
    h.relay
        .handle_remote(ConnectorEvent::Message(edited))
        .await
        .unwrap();
    assert_eq!(
        h.inline.edits.lock().unwrap().len(),
        1,
        "failed edit should be retried before marking revision applied"
    );
}

#[tokio::test]
async fn review_owner_file_from_chatgpt_is_mirrored() {
    let h = harness();
    let mut message = agent("o1", "", "r1");
    message.speaker = Speaker::Owner;
    message.files.push(RemoteFile {
        key: "a".into(),
        locator: "file-1".into(),
        name: Some("report.png".into()),
    });
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(
        h.inline.posts().len(),
        1,
        "ChatGPT owner attachment should be mirrored when /mirror is on"
    );
}

#[tokio::test(start_paused = true)]
async fn poison_message_does_not_block_following_events() {
    let h = harness();
    *h.inline.fail_post_count.lock().unwrap() = 5;
    h.connector
        .run_messages
        .lock()
        .unwrap()
        .extend([agent("bad", "bad", "r1"), agent("good", "good", "r1")]);
    let (stop, stopped) = tokio::sync::watch::channel(false);
    let relay = Arc::new(h.relay);
    let worker = tokio::spawn(async move { relay.run_remote(stopped).await });
    for _ in 0..8 {
        tokio::task::yield_now().await;
        tokio::time::advance(std::time::Duration::from_secs(60)).await;
    }
    assert_eq!(h.inline.texts(), vec!["good"]);
    assert_eq!(h.store.kv_prefix("apply_skipped:").unwrap().len(), 1);
    stop.send(true).unwrap();
    worker.await.unwrap().unwrap();
}

#[tokio::test]
async fn text_added_after_file_only_message_is_posted_once() {
    let h = harness();
    let mut message = agent("m1", "", "r1");
    message.files.push(RemoteFile {
        key: "a".into(),
        locator: "file-1".into(),
        name: Some("report.png".into()),
    });
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    message.text = "Here is the caption".into();
    message.revision = "r2".into();
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(h.inline.posts().len(), 2);
    assert_eq!(h.inline.texts()[1], "Here is the caption");
}

#[tokio::test]
async fn failed_confirmation_post_is_completed_by_replay() {
    let h = harness();
    let mut message = agent("m1", "Approve this", "r1");
    message.confirmation = Some(confirmation(ConfirmationStatus::Pending));
    *h.inline.fail_next_button_post.lock().unwrap() = true;
    assert!(
        h.relay
            .handle_remote(ConnectorEvent::Message(message.clone()))
            .await
            .is_err()
    );
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(h.inline.posts().len(), 2);
    assert_eq!(h.inline.posts()[1].1.buttons[0].len(), 2);
}

#[tokio::test]
async fn failed_reaction_replacement_is_completed_by_replay() {
    let h = harness();
    let mut message = agent("m1", "hi", "r1");
    message.agent_reaction = Some("👍".into());
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    *h.inline.fail_next_reaction.lock().unwrap() = true;
    message.agent_reaction = Some("❤️".into());
    assert!(
        h.relay
            .handle_remote(ConnectorEvent::Message(message.clone()))
            .await
            .is_err()
    );
    assert_eq!(
        h.store
            .link("m1", part::TEXT)
            .unwrap()
            .unwrap()
            .agent_reaction
            .as_deref(),
        Some("👍")
    );
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(
        h.inline
            .reactions
            .lock()
            .unwrap()
            .iter()
            .map(|(_, e, r)| (e.as_str(), *r))
            .collect::<Vec<_>>(),
        vec![("👍", false), ("👍", true), ("❤️", false)]
    );
}

#[tokio::test]
async fn failed_confirmation_close_is_retried_without_answering_twice() {
    let h = harness();
    let mut message = agent("m1", "", "r1");
    message.confirmation = Some(confirmation(ConfirmationStatus::Pending));
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    let (id, card) = &h.inline.posts()[0];
    let click = InlineEvent::Action {
        interaction_id: 1,
        message_id: *id,
        actor_id: OWNER,
        data: card.buttons[0][0].data.clone(),
    };
    *h.inline.fail_next_edit.lock().unwrap() = true;
    assert!(h.relay.handle_inline(click.clone()).await.is_err());
    h.relay.handle_inline(click).await.unwrap();
    assert_eq!(h.connector.answers.lock().unwrap().len(), 1);
    assert_eq!(
        h.store.confirmation("def-1").unwrap().unwrap().state,
        ConfirmationState::Done
    );
    assert!(
        h.inline
            .edits
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .1
            .contains("Approved")
    );
}

#[tokio::test]
async fn remote_confirmation_close_and_task_edit_retry_after_failure() {
    let h = harness();
    let mut message = agent("m1", "", "r1");
    message.confirmation = Some(confirmation(ConfirmationStatus::Pending));
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    message.confirmation = Some(confirmation(ConfirmationStatus::Closed("accepted".into())));
    message.revision = "r2".into();
    *h.inline.fail_next_edit.lock().unwrap() = true;
    assert!(
        h.relay
            .handle_remote(ConnectorEvent::Message(message.clone()))
            .await
            .is_err()
    );
    assert_eq!(
        h.store.confirmation("def-1").unwrap().unwrap().state,
        ConfirmationState::Open
    );
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    let task = |label: &str| {
        ConnectorEvent::Task(TaskUpdate {
            id: "t1".into(),
            title: None,
            label: label.into(),
            terminal: false,
            entries: Vec::new(),
        })
    };
    h.relay.handle_remote(task("Working")).await.unwrap();
    *h.inline.fail_next_edit.lock().unwrap() = true;
    assert!(h.relay.handle_remote(task("Completed")).await.is_err());
    h.relay.handle_remote(task("Completed")).await.unwrap();
    assert!(
        h.inline
            .edits
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .1
            .contains("Completed")
    );
}

#[tokio::test]
async fn task_replies_resolve_to_real_message_after_restart_and_reactions_are_ignored() {
    let h = harness();
    let mut message = agent("m1", "On it", "r1");
    message.task_id = Some("t1".into());
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    // Construct a fresh relay using the persisted store, before the card is posted.
    let relay = Relay::new(
        h.connector.clone(),
        h.inline.clone(),
        h.store.clone(),
        RelayConfig {
            owner_user_id: OWNER,
            agent_name: "Dot".into(),
            network_name: "ChatGPT".into(),
            request_salt: "bot-1".into(),
            mirror_owner_default: true,
        },
    );
    relay
        .handle_remote(ConnectorEvent::Task(TaskUpdate {
            id: "t1".into(),
            title: None,
            label: "Completed".into(),
            terminal: true,
            entries: vec![TaskEntry {
                id: "turn:answer".into(),
                speaker: Speaker::Agent,
                text: "Answer".into(),
            }],
        }))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(posts[1].1.reply_to, Some(posts[0].0));
    for (n, (target, _)) in posts[1..].iter().enumerate() {
        relay
            .handle_inline(InlineEvent::Message {
                message_id: 50 + n as i64,
                sender_id: OWNER,
                text: "follow-up".into(),
                reply_to: Some(*target),
                media: None,
                edited: false,
            })
            .await
            .unwrap();
        relay
            .handle_inline(InlineEvent::Reaction {
                message_id: *target,
                user_id: OWNER,
                emoji: "👍".into(),
                removed: false,
            })
            .await
            .unwrap();
    }
    assert!(
        h.connector
            .sends
            .lock()
            .unwrap()
            .iter()
            .all(|m| m.reply_to.as_deref() == Some("m1"))
    );
    assert_eq!(h.connector.sends.lock().unwrap().len(), 2);
    assert!(h.connector.reactions.lock().unwrap().is_empty());
}

#[tokio::test]
async fn queued_edits_replace_the_text_and_notify_once() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(FailureKind::Transient, "offline")));
    h.relay
        .handle_inline(owner_text(9, "original"))
        .await
        .unwrap();
    for text in ["edited", "final"] {
        h.relay
            .handle_inline(InlineEvent::Message {
                message_id: 9,
                sender_id: OWNER,
                text: text.into(),
                reply_to: None,
                media: None,
                edited: true,
            })
            .await
            .unwrap();
    }
    assert_eq!(h.store.pending_by_inline(9).unwrap().unwrap().text, "final");
    h.store
        .defer_send(&correlation_id("bot-1", 9), 1, 0)
        .unwrap();
    h.relay.retry_pending().await.unwrap();
    assert_eq!(h.connector.sends.lock().unwrap()[1].text, "final");
    assert_eq!(
        h.inline
            .texts()
            .iter()
            .filter(|t| t.contains("Updated the queued"))
            .count(),
        1
    );
}

#[tokio::test]
async fn recovered_send_reports_delay_once_even_after_first_attempt() {
    let h = harness();
    let request = correlation_id("bot-1", 9);
    h.store
        .reserve_send(&PendingSend {
            request_id: request.clone(),
            inline_id: 9,
            reply_to: None,
            text: "hi".into(),
            media: None,
            attempts: 0,
            next_attempt_at: 0,
        })
        .unwrap();
    for n in 0..2 {
        h.connector
            .find_results
            .lock()
            .unwrap()
            .push_back(Err(ConnectorError::new(FailureKind::Transient, "offline")));
        h.store.defer_send(&request, n, 0).unwrap();
        h.relay.retry_pending().await.unwrap();
    }
    assert_eq!(h.inline.texts().len(), 1);
    assert!(h.inline.texts()[0].starts_with("Not delivered yet"));
}

#[tokio::test]
async fn queued_edit_after_an_uncertain_send_reports_the_version_that_landed() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(
            FailureKind::Uncertain,
            "lost response",
        )));
    h.relay
        .handle_inline(owner_text(9, "original"))
        .await
        .unwrap();
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 9,
            sender_id: OWNER,
            text: "edited".into(),
            reply_to: None,
            media: None,
            edited: true,
        })
        .await
        .unwrap();
    h.connector
        .find_results
        .lock()
        .unwrap()
        .push_back(Ok(Some("landed".into())));
    h.store
        .defer_send(&correlation_id("bot-1", 9), 1, 0)
        .unwrap();
    h.relay.retry_pending().await.unwrap();
    assert_eq!(h.connector.sends.lock().unwrap().len(), 1);
    assert!(h.store.pending_sends().unwrap().is_empty());
    assert!(h.inline.texts().last().unwrap().contains("earlier version"));
}

#[tokio::test]
async fn removed_caption_is_reflected_without_removing_its_file() {
    let h = harness();
    let mut message = agent("m1", "caption", "r1");
    message.files.push(RemoteFile {
        key: "a".into(),
        locator: "file-1".into(),
        name: Some("report.png".into()),
    });
    h.relay
        .handle_remote(ConnectorEvent::Message(message.clone()))
        .await
        .unwrap();
    message.text.clear();
    message.revision = "r2".into();
    h.relay
        .handle_remote(ConnectorEvent::Message(message))
        .await
        .unwrap();
    assert_eq!(h.inline.posts().len(), 2);
    assert_eq!(
        h.inline.edits.lock().unwrap()[0].1,
        "_Text removed in ChatGPT._"
    );
}

#[tokio::test]
async fn owner_message_from_remote_is_not_sent_back() {
    let h = harness();
    let typed = RemoteMessage {
        speaker: Speaker::Owner,
        ..agent("o1", "from my phone", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(typed.clone()))
        .await
        .unwrap();
    let inline_id = h.inline.posts()[0].0;
    // The bot then sees it as a new owner message in the DM.
    h.relay
        .handle_inline(owner_text(inline_id, "from my phone"))
        .await
        .unwrap();
    assert!(h.connector.sends.lock().unwrap().is_empty(), "no echo loop");
    // A remote edit edits the owner's message, not a bot message.
    let edited = RemoteMessage {
        text: "from my phone (edited)".into(),
        revision: "r2".into(),
        ..typed
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(edited))
        .await
        .unwrap();
    assert_eq!(
        h.inline.owner_edits.lock().unwrap().clone(),
        vec![(inline_id, "from my phone (edited)".to_owned())]
    );
    assert!(h.inline.edits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn owner_reaction_in_remote_app_shows_as_owner_and_echo_is_noop() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "hi", "r1")))
        .await
        .unwrap();
    let inline_id = h.inline.posts()[0].0;
    let reacted = RemoteMessage {
        owner_reaction: Some("🔥".into()),
        ..agent("m1", "hi", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(reacted))
        .await
        .unwrap();
    assert_eq!(
        h.inline.owner_reactions.lock().unwrap().clone(),
        vec![(inline_id, "🔥".to_owned(), false)]
    );
    // The bot sees the owner's reaction land in Inline: not sent back.
    h.relay
        .handle_inline(InlineEvent::Reaction {
            message_id: inline_id,
            user_id: OWNER,
            emoji: "🔥".into(),
            removed: false,
        })
        .await
        .unwrap();
    assert!(h.connector.reactions.lock().unwrap().is_empty());
    // Cleared in ChatGPT: cleared in Inline.
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "hi", "r1")))
        .await
        .unwrap();
    assert_eq!(
        h.inline.owner_reactions.lock().unwrap().last().cloned(),
        Some((inline_id, "🔥".to_owned(), true))
    );
}

#[tokio::test]
async fn switching_reaction_in_inline_keeps_one_like_chatgpt() {
    let h = harness();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m1", "hi", "r1")))
        .await
        .unwrap();
    let inline_id = h.inline.posts()[0].0;
    for emoji in ["👍", "❤️"] {
        h.relay
            .handle_inline(InlineEvent::Reaction {
                message_id: inline_id,
                user_id: OWNER,
                emoji: emoji.into(),
                removed: false,
            })
            .await
            .unwrap();
    }
    assert_eq!(
        h.inline.owner_reactions.lock().unwrap().clone(),
        vec![(inline_id, "👍".to_owned(), true)],
        "the replaced reaction is cleared in Inline too"
    );
}

#[tokio::test]
async fn task_only_message_becomes_the_card_in_place() {
    let h = harness();
    let mut started = agent("m1", "", "r1");
    started.task_id = Some("t1".into());
    h.relay
        .handle_remote(ConnectorEvent::Message(started.clone()))
        .await
        .unwrap();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("m2", "I opened it.", "r1")))
        .await
        .unwrap();
    let posts = h.inline.posts();
    assert_eq!(
        posts[0].1.text, "🗂 **Task**\nStarting…",
        "card keeps the message's place"
    );
    assert_eq!(posts[1].1.text, "I opened it.");
    let card = posts[0].0;
    // Replay does not post a second card.
    h.relay
        .handle_remote(ConnectorEvent::Message(started))
        .await
        .unwrap();
    h.relay
        .handle_remote(ConnectorEvent::Task(TaskUpdate {
            id: "t1".into(),
            title: Some("Say hi".into()),
            label: "Completed".into(),
            terminal: true,
            entries: Vec::new(),
        }))
        .await
        .unwrap();
    assert_eq!(h.inline.posts().len(), 2);
    assert_eq!(
        h.inline.edits.lock().unwrap().last().cloned(),
        Some((card, "🗂 **Say hi**\nCompleted".to_owned(), usize::MAX))
    );
    // A reply to the card answers the task's message.
    h.relay
        .handle_inline(InlineEvent::Message {
            message_id: 9,
            sender_id: OWNER,
            text: "thanks".into(),
            reply_to: Some(card),
            media: None,
            edited: false,
        })
        .await
        .unwrap();
    assert_eq!(
        h.connector.sends.lock().unwrap()[0].reply_to.as_deref(),
        Some("m1")
    );
}

#[tokio::test]
async fn unavailable_network_keeps_the_message_queued_past_the_retry_limit() {
    let h = harness();
    let unavailable = || {
        Err(ConnectorError::new(
            FailureKind::Unavailable,
            "not offered in this region",
        ))
    };
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(unavailable());
    h.relay.handle_inline(owner_text(9, "hi")).await.unwrap();
    let request = correlation_id("bot-1", 9);
    // Far past MAX_SEND_ATTEMPTS: still queued, one notice, no failure.
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(unavailable());
    h.store.defer_send(&request, 20, 0).unwrap();
    h.relay.retry_pending().await.unwrap();
    assert_eq!(h.store.pending_sends().unwrap().len(), 1);
    let texts = h.inline.texts();
    assert_eq!(texts.len(), 1, "{texts:?}");
    assert!(texts[0].starts_with("Not delivered yet (not offered in this region)"));

    // Back in a supported location: it goes out.
    h.store.defer_send(&request, 21, 0).unwrap();
    h.relay.retry_pending().await.unwrap();
    assert!(h.store.pending_sends().unwrap().is_empty());
    assert_eq!(h.connector.sends.lock().unwrap().len(), 3);
}

fn guest(chat_id: i64, message_id: i64, text: &str) -> InlineEvent {
    InlineEvent::Guest {
        chat_id,
        message_id,
        sender_name: "Alice".into(),
        chat_title: Some("Pricing".into()),
        text: text.into(),
    }
}

/// Sends a guest message and applies its echo; returns the remote id.
async fn send_guest(h: &Harness, chat_id: i64, message_id: i64, text: &str) -> String {
    h.relay
        .handle_inline(guest(chat_id, message_id, text))
        .await
        .unwrap();
    let sent = h.connector.sends.lock().unwrap().last().cloned().unwrap();
    let remote_id = format!("remote-sent-{}", h.connector.sends.lock().unwrap().len());
    let echo = RemoteMessage {
        speaker: Speaker::Owner,
        client_request_id: Some(sent.request_id),
        ..agent(&remote_id, &sent.text, "e1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(echo))
        .await
        .unwrap();
    remote_id
}

#[tokio::test]
async fn guest_request_is_labelled_and_the_answer_goes_back_to_them() {
    let h = harness();
    send_guest(&h, 77, 5, "signup numbers?").await;
    let sent = h.connector.sends.lock().unwrap().clone();
    assert_eq!(sent.len(), 1);
    assert!(
        sent[0]
            .text
            .starts_with("💬 From Alice via Inline in “Pricing”")
    );
    assert!(sent[0].text.ends_with("signup numbers?"));
    // Redelivery doesn't send again; the echo never reaches the owner DM.
    h.relay
        .handle_inline(guest(77, 5, "signup numbers?"))
        .await
        .unwrap();
    assert_eq!(h.connector.sends.lock().unwrap().len(), 1);
    assert!(h.inline.posts().is_empty());

    let answer = agent("a1", "About 420.", "r1");
    h.relay
        .handle_remote(ConnectorEvent::Message(answer.clone()))
        .await
        .unwrap();
    let posts = h.inline.guest_posts.lock().unwrap().clone();
    assert_eq!(posts.len(), 1);
    assert_eq!((posts[0].0, posts[0].2.reply_to), (77, Some(5)));
    assert_eq!(posts[0].2.text, "About 420.");
    assert!(h.inline.posts().is_empty());

    let edited = RemoteMessage {
        text: "About 430.".into(),
        revision: "r2".into(),
        ..answer
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(edited))
        .await
        .unwrap();
    assert_eq!(
        h.inline.guest_edits.lock().unwrap().clone(),
        vec![(77, posts[0].1, "About 430.".to_owned())]
    );
}

#[tokio::test]
async fn owner_takes_answers_back_but_replies_still_reach_the_guest() {
    let h = harness();
    let request = send_guest(&h, 77, 5, "hi").await;
    h.relay
        .handle_inline(owner_text(10, "my turn"))
        .await
        .unwrap();
    h.relay
        .handle_remote(ConnectorEvent::Message(agent("a1", "for the owner", "r1")))
        .await
        .unwrap();
    assert_eq!(h.inline.texts(), vec!["for the owner"]);
    let threaded = RemoteMessage {
        reply_to: Some(request),
        ..agent("a2", "for Alice", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(threaded))
        .await
        .unwrap();
    let posts = h.inline.guest_posts.lock().unwrap().clone();
    assert_eq!(posts.len(), 1);
    assert_eq!((posts[0].0, posts[0].2.text.as_str()), (77, "for Alice"));
}

#[tokio::test]
async fn confirmations_and_tasks_stay_with_the_owner() {
    let h = harness();
    send_guest(&h, 77, 5, "book it").await;
    let task = RemoteMessage {
        task_id: Some("t1".into()),
        ..agent("a1", "Working on it", "r1")
    };
    h.relay
        .handle_remote(ConnectorEvent::Message(task))
        .await
        .unwrap();
    assert!(h.inline.guest_posts.lock().unwrap().is_empty());
    assert!(!h.inline.posts().is_empty());
}

#[tokio::test]
async fn failed_guest_send_tells_the_guest() {
    let h = harness();
    h.connector
        .send_results
        .lock()
        .unwrap()
        .push_back(Err(ConnectorError::new(FailureKind::Transient, "503")));
    h.relay.handle_inline(guest(77, 5, "hi")).await.unwrap();
    let posts = h.inline.guest_posts.lock().unwrap().clone();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].2.text.starts_with("Couldn't send this to Dot"));
}

#[tokio::test]
async fn unknown_owner_commands_go_to_the_inline_side() {
    let h = harness();
    h.relay
        .handle_inline(owner_text(10, "/share @alice"))
        .await
        .unwrap();
    assert_eq!(h.inline.texts(), vec!["shared with @alice"]);
    assert!(h.connector.sends.lock().unwrap().is_empty());
}
