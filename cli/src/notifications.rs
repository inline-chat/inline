use clap::ValueEnum;

use crate::output;
use crate::protocol::proto;

#[derive(Clone, Copy, Debug, ValueEnum)]
pub(crate) enum NotificationModeArg {
    All,
    None,
    Mentions,
    #[value(name = "only-mentions", alias = "only_mentions")]
    OnlyMentions,
}

pub(crate) struct NotificationSettingsValues {
    pub(crate) mode: proto::notification_settings::Mode,
    pub(crate) silent: bool,
    pub(crate) disable_dm_notifications: bool,
}

pub(crate) fn notification_settings_values(
    settings: Option<&proto::NotificationSettings>,
) -> NotificationSettingsValues {
    let raw_mode = settings
        .and_then(|value| value.mode)
        .and_then(|value| proto::notification_settings::Mode::try_from(value).ok());
    let mut mode = match raw_mode {
        Some(proto::notification_settings::Mode::All) => proto::notification_settings::Mode::All,
        Some(proto::notification_settings::Mode::None) => proto::notification_settings::Mode::None,
        Some(proto::notification_settings::Mode::Mentions) => {
            proto::notification_settings::Mode::Mentions
        }
        Some(proto::notification_settings::Mode::ImportantOnly) => {
            proto::notification_settings::Mode::Mentions
        }
        Some(proto::notification_settings::Mode::OnlyMentions) => {
            proto::notification_settings::Mode::OnlyMentions
        }
        _ => proto::notification_settings::Mode::All,
    };
    let silent = settings.and_then(|value| value.silent).unwrap_or(false);
    let mut disable_dm_notifications = settings
        .and_then(|value| value.disable_dm_notifications)
        .unwrap_or(false);

    if raw_mode == Some(proto::notification_settings::Mode::ImportantOnly) {
        disable_dm_notifications = false;
    }
    if mode == proto::notification_settings::Mode::Mentions && disable_dm_notifications {
        mode = proto::notification_settings::Mode::OnlyMentions;
    }
    if mode == proto::notification_settings::Mode::OnlyMentions {
        disable_dm_notifications = true;
    }

    NotificationSettingsValues {
        mode,
        silent,
        disable_dm_notifications,
    }
}

pub(crate) fn notification_mode_from_arg(
    mode: NotificationModeArg,
) -> proto::notification_settings::Mode {
    match mode {
        NotificationModeArg::All => proto::notification_settings::Mode::All,
        NotificationModeArg::None => proto::notification_settings::Mode::None,
        NotificationModeArg::Mentions => proto::notification_settings::Mode::Mentions,
        NotificationModeArg::OnlyMentions => proto::notification_settings::Mode::OnlyMentions,
    }
}

fn notification_mode_label(mode: proto::notification_settings::Mode) -> &'static str {
    match mode {
        proto::notification_settings::Mode::All => "all",
        proto::notification_settings::Mode::None => "none",
        proto::notification_settings::Mode::Mentions => "mentions",
        proto::notification_settings::Mode::OnlyMentions => "only-mentions",
        proto::notification_settings::Mode::ImportantOnly => "mentions",
        _ => "all",
    }
}

pub(crate) fn print_notification_settings(settings: Option<&proto::UserSettings>) {
    let values = notification_settings_values(
        settings.and_then(|value| value.notification_settings.as_ref()),
    );
    println!("{}", output::style_heading("Notification settings"));
    println!("  mode: {}", notification_mode_label(values.mode));
    println!("  silent: {}", if values.silent { "yes" } else { "no" });
    println!(
        "  disable dm notifications: {}",
        if values.disable_dm_notifications {
            "yes"
        } else {
            "no"
        }
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_notification_settings_are_all_with_sound() {
        let values = notification_settings_values(None);

        assert_eq!(values.mode, proto::notification_settings::Mode::All);
        assert!(!values.silent);
        assert!(!values.disable_dm_notifications);
    }

    #[test]
    fn mention_mode_with_dm_disabled_normalizes_to_only_mentions() {
        let settings = proto::NotificationSettings {
            mode: Some(proto::notification_settings::Mode::Mentions as i32),
            disable_dm_notifications: Some(true),
            ..Default::default()
        };

        let values = notification_settings_values(Some(&settings));

        assert_eq!(
            values.mode,
            proto::notification_settings::Mode::OnlyMentions
        );
        assert!(values.disable_dm_notifications);
    }

    #[test]
    fn only_mentions_mode_forces_dm_disabled_flag() {
        let settings = proto::NotificationSettings {
            mode: Some(proto::notification_settings::Mode::OnlyMentions as i32),
            disable_dm_notifications: Some(false),
            ..Default::default()
        };

        let values = notification_settings_values(Some(&settings));

        assert_eq!(
            values.mode,
            proto::notification_settings::Mode::OnlyMentions
        );
        assert!(values.disable_dm_notifications);
    }

    #[test]
    fn legacy_important_only_maps_to_mentions() {
        let settings = proto::NotificationSettings {
            mode: Some(proto::notification_settings::Mode::ImportantOnly as i32),
            disable_dm_notifications: Some(true),
            ..Default::default()
        };

        let values = notification_settings_values(Some(&settings));

        assert_eq!(values.mode, proto::notification_settings::Mode::Mentions);
        assert!(!values.disable_dm_notifications);
    }
}
