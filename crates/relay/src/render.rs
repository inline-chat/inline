//! Text the relay posts in Inline. Kept in one place so copy stays consistent
//! across connectors.

use crate::engine::RelayHealth;
use crate::model::{Confirmation, ConnectorHealth, TaskUpdate};

/// Longest text the relay posts; longer remote text is cut with a pointer.
pub const MAX_TEXT_CHARS: usize = 16_000;

fn clip(text: &str, suffix: &str) -> String {
    if text.chars().count() <= MAX_TEXT_CHARS {
        return text.to_owned();
    }
    let mut clipped: String = text.chars().take(MAX_TEXT_CHARS).collect();
    clipped.push_str(suffix);
    clipped
}

/// An agent message.
pub fn agent_text(text: &str) -> String {
    clip(text, "\n\n_…cut here; the rest is in the original conversation._")
}

/// A message the owner typed in the remote app.
pub fn owner_mirror(network: &str, text: &str) -> String {
    let quoted = clip(text, "…")
        .lines()
        .map(|line| format!("> {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    format!("_You, in {network}:_\n{quoted}")
}

/// Replacement for a message deleted remotely.
pub fn deleted(network: &str) -> String {
    format!("_Deleted in {network}._")
}

/// Placeholder for a file that could not be mirrored.
pub fn file_unavailable(name: &str, network: &str) -> String {
    format!("📎 {name} — couldn't be loaded here. Open it in {network}.")
}

/// Confirmation card body (without its status line).
pub fn confirmation_body(confirmation: &Confirmation) -> String {
    let mut text = format!(
        "**{}**\n{}",
        confirmation
            .title
            .as_deref()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or("Confirmation needed"),
        confirmation.message
    );
    for (label, value) in &confirmation.fields {
        text.push_str(&format!("\n• {label}: {value}"));
    }
    text
}

/// A closed confirmation card.
pub fn confirmation_closed(body: &str, status: &str) -> String {
    format!("{body}\n\n_{status}_")
}

/// Status line for a confirmation closed remotely.
pub fn closed_status(status: &str) -> String {
    match status {
        "accepted" | "applied" | "approved" => "Approved.".into(),
        "declined" | "rejected" => "Declined.".into(),
        "expired" => "Expired.".into(),
        "cancelled" | "canceled" => "Cancelled.".into(),
        other => format!("No longer waiting ({other})."),
    }
}

/// A task card.
pub fn task_card(task: &TaskUpdate) -> String {
    format!(
        "🗂 **{}**\n{}",
        task.title
            .as_deref()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or("Task"),
        task.label
    )
}

/// `/help`.
pub fn help(agent: &str, network: &str) -> String {
    format!(
        "This chat is a bridge to your {network} {agent}. Messages, replies, reactions, and files go both ways.\n\n\
         `/status` — bridge and {network} connection\n\
         `/mirror on|off` — show messages you type in {network} here\n\
         `/help` — this message\n\n\
         Edits and deletions made here stay in Inline."
    )
}

/// `/status`.
pub fn status(network: &str, health: &RelayHealth, detail: &str, mirror: bool) -> String {
    let connection = match &health.connector {
        None => "starting".to_owned(),
        Some(ConnectorHealth::Ready) => "connected".to_owned(),
        Some(ConnectorHealth::Degraded(reason)) => format!("degraded ({reason})"),
        Some(ConnectorHealth::NeedsLogin(reason)) => format!("sign-in needed ({reason})"),
    };
    let mut text = format!("{network}: {connection}\n{detail}");
    if health.pending_sends > 0 {
        text.push_str(&format!(
            "\nWaiting to deliver: {} message(s)",
            health.pending_sends
        ));
    }
    text.push_str(&format!(
        "\nMirroring messages you type in {network}: {}",
        if mirror { "on" } else { "off" }
    ));
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_mirror_quotes_every_line() {
        assert_eq!(
            owner_mirror("ChatGPT", "a\nb"),
            "_You, in ChatGPT:_\n> a\n> b"
        );
    }

    #[test]
    fn long_text_is_clipped() {
        let text = "x".repeat(MAX_TEXT_CHARS + 10);
        let clipped = agent_text(&text);
        assert!(clipped.starts_with(&"x".repeat(MAX_TEXT_CHARS)));
        assert!(clipped.contains("cut here"));
    }
}
