//! Realtime signals from `ws.chatgpt.com`.
//!
//! The socket only says "something changed" and carries the Dot's typing
//! heartbeat; all content is reconciled over REST. Connecting publishes the
//! account's presence as `background`, the same state the ChatGPT apps use
//! when not in the foreground.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use url::Url;

use crate::error::{DotsError, DotsResult};

/// Messaging topic.
pub const TOPIC: &str = "calpico-chatgpt-messaging";
const SUBSCRIBE_TIMEOUT: Duration = Duration::from_secs(30);
const PING_INTERVAL: Duration = Duration::from_secs(30);
const PONG_TIMEOUT: Duration = Duration::from_secs(15);

/// What the socket tells the poller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Signal {
    /// Subscribed; poll now to close any gap.
    Subscribed,
    /// Something in the room changed; poll now.
    Wake,
    /// The Dot started or stopped responding.
    Typing(bool),
    /// The socket dropped; poll on the fallback interval until it is back.
    Disconnected(String),
}

/// Which websocket URLs to accept.
#[derive(Clone, Debug)]
pub struct RealtimePolicy {
    /// Exact host (production: `ws.chatgpt.com`).
    pub host: String,
    /// Allow `ws://` (tests only).
    pub allow_plain: bool,
}

impl Default for RealtimePolicy {
    fn default() -> Self {
        Self {
            host: "ws.chatgpt.com".into(),
            allow_plain: false,
        }
    }
}

impl RealtimePolicy {
    fn check(&self, url: &Url) -> DotsResult<()> {
        let scheme_ok = url.scheme() == "wss" || (self.allow_plain && url.scheme() == "ws");
        if !scheme_ok || url.host_str() != Some(self.host.as_str()) {
            return Err(DotsError::Realtime("unexpected websocket host".into()));
        }
        Ok(())
    }
}

/// The frame sent right after connecting.
pub fn subscribe_frame() -> String {
    json!([
        {"id": 1, "command": {"type": "connect", "presence": {"type": "presence", "state": "background"}}},
        {"id": 2, "command": {"type": "subscribe", "topic_id": TOPIC}}
    ])
    .to_string()
}

/// Interprets one incoming frame (a JSON array of envelopes).
pub fn interpret_frame(text: &str, room_id: &str, dot_member: &str) -> Vec<Signal> {
    let Ok(Value::Array(envelopes)) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };
    let mut signals = Vec::new();
    for envelope in envelopes {
        if envelope.get("id").and_then(Value::as_u64) == Some(2)
            && envelope.pointer("/reply/type").and_then(Value::as_str) == Some("subscribe")
            && envelope.pointer("/reply/topic_id").and_then(Value::as_str) == Some(TOPIC)
        {
            signals.push(Signal::Subscribed);
            continue;
        }
        if envelope.get("type").and_then(Value::as_str) != Some("message")
            || envelope.get("topic_id").and_then(Value::as_str) != Some(TOPIC)
        {
            continue;
        }
        let Some(signal) = envelope.get("payload") else {
            continue;
        };
        let kind = signal.get("type").and_then(Value::as_str).unwrap_or("");
        let payload = signal.get("payload").unwrap_or(&Value::Null);
        if payload.get("room_id").and_then(Value::as_str) != Some(room_id) {
            continue;
        }
        match kind {
            "calpico-is-responding-heartbeat" => {
                let from_dot = payload.pointer("/source/role").and_then(Value::as_str)
                    == Some("user")
                    && payload
                        .pointer("/source/account_user_id")
                        .and_then(Value::as_str)
                        == Some(dot_member);
                if from_dot {
                    let typing = payload
                        .get("typing")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    signals.push(Signal::Typing(typing));
                }
            }
            "calpico-message-add" => {
                if payload
                    .pointer("/message/account_user_id")
                    .and_then(Value::as_str)
                    == Some(dot_member)
                {
                    signals.push(Signal::Typing(false));
                }
                signals.push(Signal::Wake);
            }
            _ => signals.push(Signal::Wake),
        }
    }
    signals
}

/// One socket session: connect, subscribe, forward signals until it drops.
pub async fn session(
    url: &Url,
    policy: &RealtimePolicy,
    room_id: &str,
    dot_member: &str,
    signals: &mpsc::Sender<Signal>,
) -> DotsResult<()> {
    policy.check(url)?;
    let (mut socket, _) = tokio::time::timeout(
        Duration::from_secs(30),
        tokio_tungstenite::connect_async(url.as_str()),
    )
    .await
    .map_err(|_| DotsError::Realtime("connect timed out".into()))?
    .map_err(|error| DotsError::Realtime(format!("connect failed: {}", short(&error))))?;
    socket
        .send(WsMessage::Text(subscribe_frame().into()))
        .await
        .map_err(|error| DotsError::Realtime(short(&error)))?;

    let deadline = tokio::time::Instant::now() + SUBSCRIBE_TIMEOUT;
    let mut subscribed = false;
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_INTERVAL, PING_INTERVAL);
    let mut awaiting_pong: Option<tokio::time::Instant> = None;
    loop {
        let pong_deadline = awaiting_pong.map(|sent| sent + PONG_TIMEOUT);
        tokio::select! {
            frame = socket.next() => {
                let frame = match frame {
                    None => return Err(DotsError::Realtime("socket closed".into())),
                    Some(Err(error)) => return Err(DotsError::Realtime(short(&error))),
                    Some(Ok(frame)) => frame,
                };
                match frame {
                    WsMessage::Text(text) => {
                        for signal in interpret_frame(text.as_str(), room_id, dot_member) {
                            if signal == Signal::Subscribed {
                                subscribed = true;
                            }
                            if signals.send(signal).await.is_err() {
                                return Ok(());
                            }
                        }
                    }
                    WsMessage::Pong(_) => awaiting_pong = None,
                    WsMessage::Close(_) => return Err(DotsError::Realtime("socket closed".into())),
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(deadline), if !subscribed => {
                return Err(DotsError::Realtime("subscription was not confirmed".into()));
            }
            _ = ping.tick() => {
                if awaiting_pong.is_none() {
                    socket
                        .send(WsMessage::Ping(Vec::new().into()))
                        .await
                        .map_err(|error| DotsError::Realtime(short(&error)))?;
                    awaiting_pong = Some(tokio::time::Instant::now());
                }
            }
            _ = async { tokio::time::sleep_until(pong_deadline.unwrap()).await }, if pong_deadline.is_some() => {
                return Err(DotsError::Realtime("keepalive timed out".into()));
            }
        }
    }
}

fn short(error: &dyn std::fmt::Display) -> String {
    // Websocket errors can echo the URL, which carries a credential.
    let text = error.to_string();
    match text.find("://") {
        Some(_) => "websocket error".into(),
        None => text.chars().take(120).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn envelope(kind: &str, payload: Value) -> String {
        json!([{"id": 9, "type": "message", "topic_id": TOPIC, "payload": {"type": kind, "payload": payload}}])
            .to_string()
    }

    #[test]
    fn subscribe_reply_is_recognized() {
        let frame = json!([{"id": 2, "reply": {"type": "subscribe", "topic_id": TOPIC}}]).to_string();
        assert_eq!(interpret_frame(&frame, "r", "d"), vec![Signal::Subscribed]);
    }

    #[test]
    fn heartbeat_from_dot_is_typing() {
        let frame = envelope(
            "calpico-is-responding-heartbeat",
            json!({"room_id": "r", "source": {"role": "user", "account_user_id": "d"}}),
        );
        assert_eq!(interpret_frame(&frame, "r", "d"), vec![Signal::Typing(true)]);
        let stop = envelope(
            "calpico-is-responding-heartbeat",
            json!({"room_id": "r", "typing": false, "source": {"role": "user", "account_user_id": "d"}}),
        );
        assert_eq!(interpret_frame(&stop, "r", "d"), vec![Signal::Typing(false)]);
        let other = envelope(
            "calpico-is-responding-heartbeat",
            json!({"room_id": "r", "source": {"role": "user", "account_user_id": "owner"}}),
        );
        assert!(interpret_frame(&other, "r", "d").is_empty());
    }

    #[test]
    fn dot_message_clears_typing_and_wakes() {
        let frame = envelope(
            "calpico-message-add",
            json!({"room_id": "r", "message": {"account_user_id": "d"}}),
        );
        assert_eq!(
            interpret_frame(&frame, "r", "d"),
            vec![Signal::Typing(false), Signal::Wake]
        );
    }

    #[test]
    fn other_rooms_are_ignored() {
        let frame = envelope("calpico-message-update", json!({"room_id": "elsewhere"}));
        assert!(interpret_frame(&frame, "r", "d").is_empty());
        assert!(interpret_frame("not json", "r", "d").is_empty());
    }

    #[test]
    fn policy_requires_exact_host() {
        let policy = RealtimePolicy::default();
        assert!(policy.check(&Url::parse("wss://ws.chatgpt.com/x?t=1").unwrap()).is_ok());
        assert!(policy.check(&Url::parse("ws://ws.chatgpt.com/x").unwrap()).is_err());
        assert!(policy.check(&Url::parse("wss://evil.example/x").unwrap()).is_err());
    }
}
