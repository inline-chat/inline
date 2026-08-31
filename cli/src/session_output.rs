use inline_protocol::proto;

use crate::output::{format_relative_date, style_heading, terminal_text};

pub(crate) fn print_sessions(sessions: &[proto::AccountSession], now: i64) {
    println!("{}", style_heading("Sessions"));
    if sessions.is_empty() {
        println!("  No account sessions.");
        return;
    }
    for session in sessions {
        let current = if session.current { "*" } else { " " };
        let active = if session.active { "active" } else { "inactive" };
        let raw_label = session_label(session);
        let label = terminal_text(&raw_label);
        let last_active = format_relative_date(session.last_active_at, now);
        println!(
            "{current} {:>6}  {label}  {active}, {last_active}",
            session.id
        );
        let details = session_details(session);
        if !details.is_empty() {
            println!("          {}", terminal_text(&details));
        }
    }
    println!("\n* current session");
}

fn session_label(session: &proto::AccountSession) -> String {
    session
        .device_name
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&session.client_type)
        .to_string()
}

fn session_details(session: &proto::AccountSession) -> String {
    let mut details = Vec::new();
    if session
        .device_name
        .as_deref()
        .is_some_and(|name| !name.trim().is_empty() && name.trim() != session.client_type)
    {
        details.push(session.client_type.clone());
    }
    if let Some(version) = session
        .client_version
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        details.push(format!("v{version}"));
    }
    if let Some(os_version) = session
        .os_version
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        details.push(os_version.to_string());
    }
    let location = [session.city.as_deref(), session.country.as_deref()]
        .into_iter()
        .flatten()
        .filter(|value| !value.trim().is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    if !location.is_empty() {
        details.push(location);
    }
    details.join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_prefer_device_names_and_details_preserve_client_identity() {
        let session = proto::AccountSession {
            client_type: "CLI".to_string(),
            device_name: Some("Work Mac".to_string()),
            client_version: Some("0.7.7".to_string()),
            os_version: Some("macOS 27".to_string()),
            city: Some("Tehran".to_string()),
            country: Some("Iran".to_string()),
            ..Default::default()
        };

        assert_eq!(session_label(&session), "Work Mac");
        assert_eq!(
            session_details(&session),
            "CLI · v0.7.7 · macOS 27 · Tehran, Iran"
        );
    }

    #[test]
    fn empty_metadata_falls_back_to_client_type() {
        let session = proto::AccountSession {
            client_type: "InlineMac".to_string(),
            device_name: Some("  ".to_string()),
            ..Default::default()
        };

        assert_eq!(session_label(&session), "InlineMac");
        assert_eq!(session_details(&session), "");
    }
}
