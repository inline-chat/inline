//! Who can message a bot besides its owner, chosen where a bot is created or
//! set up. A new bot is private; these flags share it in the same step, so
//! nobody finds out later that their team can't reach it.

use clap::Args;
use inline_protocol::proto;

use crate::errors::CliError;

/// Operations a person or a space gets from `--share-user` / `--share-space`.
const SHARE_OPERATIONS: [proto::AgentGrantOperation; 2] = [
    proto::AgentGrantOperation::Invoke,
    proto::AgentGrantOperation::Steer,
];

/// An admin manages the bot with its owner: access, profile, settings and
/// token. Deleting the bot and approving its tool requests stay with the owner.
pub(crate) const ADMIN_OPERATIONS: [proto::AgentGrantOperation; 3] = [
    proto::AgentGrantOperation::Invoke,
    proto::AgentGrantOperation::Steer,
    proto::AgentGrantOperation::Configure,
];

#[derive(Args, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct BotSharingArgs {
    /// Let this person message the bot; may be repeated.
    #[arg(long = "share-user", value_name = "USER_ID")]
    pub(crate) share_users: Vec<i64>,
    /// Let everyone in this space message the bot; may be repeated.
    #[arg(long = "share-space", value_name = "SPACE_ID")]
    pub(crate) share_spaces: Vec<i64>,
    /// Make this person an admin who manages the bot with you; may be repeated.
    #[arg(long = "admin", value_name = "USER_ID")]
    pub(crate) admins: Vec<i64>,
}

impl BotSharingArgs {
    /// One access-list entry per person or space, in the order given. Someone
    /// named both ways is an admin.
    pub(crate) fn grants(
        &self,
        bot_user_id: i64,
    ) -> Result<Vec<proto::SetAgentGrantInput>, CliError> {
        let positive = |flag: &str, id: i64| {
            if id > 0 {
                Ok(id)
            } else {
                Err(CliError::invalid_args(format!(
                    "{flag} must be a positive id"
                )))
            }
        };
        let operations = |operations: &[proto::AgentGrantOperation]| {
            operations
                .iter()
                .map(|operation| *operation as i32)
                .collect::<Vec<_>>()
        };
        let user = |user_id: i64, ops: &[proto::AgentGrantOperation]| proto::SetAgentGrantInput {
            bot_user_id,
            user_id,
            operations: operations(ops),
            subject: Some(proto::AccessSubject {
                subject: Some(proto::access_subject::Subject::UserId(user_id)),
            }),
        };

        let mut grants = Vec::new();
        let mut seen_users = Vec::new();
        for id in &self.admins {
            let id = positive("--admin", *id)?;
            if !seen_users.contains(&id) {
                seen_users.push(id);
                grants.push(user(id, &ADMIN_OPERATIONS));
            }
        }
        for id in &self.share_users {
            let id = positive("--share-user", *id)?;
            if !seen_users.contains(&id) {
                seen_users.push(id);
                grants.push(user(id, &SHARE_OPERATIONS));
            }
        }
        let mut seen_spaces = Vec::new();
        for id in &self.share_spaces {
            let id = positive("--share-space", *id)?;
            if !seen_spaces.contains(&id) {
                seen_spaces.push(id);
                grants.push(proto::SetAgentGrantInput {
                    bot_user_id,
                    user_id: 0,
                    // A whole space messages the bot; steering stays with people you name.
                    operations: operations(&[proto::AgentGrantOperation::Invoke]),
                    subject: Some(proto::AccessSubject {
                        subject: Some(proto::access_subject::Subject::SpaceId(id)),
                    }),
                });
            }
        }
        Ok(grants)
    }

    /// "2 people, 1 space and 1 admin", for the line that says who has access.
    fn summary(&self) -> Option<String> {
        let dedup = |ids: &[i64]| {
            let mut ids = ids.to_vec();
            ids.sort_unstable();
            ids.dedup();
            ids
        };
        let admins = dedup(&self.admins);
        let people = dedup(&self.share_users)
            .into_iter()
            .filter(|id| !admins.contains(id))
            .count();
        let spaces = dedup(&self.share_spaces).len();
        let count = |count: usize, one: &str, many: &str| match count {
            0 => None,
            1 => Some(format!("1 {one}")),
            count => Some(format!("{count} {many}")),
        };
        let parts: Vec<String> = [
            count(people, "person", "people"),
            count(spaces, "space", "spaces"),
            count(admins.len(), "admin", "admins"),
        ]
        .into_iter()
        .flatten()
        .collect();
        match parts.as_slice() {
            [] => None,
            [one] => Some(one.clone()),
            [rest @ .., last] => Some(format!("{} and {last}", rest.join(", "))),
        }
    }
}

/// What to tell someone right after their bot exists: who can message it, and
/// the two ways to change that.
pub(crate) fn access_summary_lines(
    bot_user_id: i64,
    sharing: &BotSharingArgs,
    open_to_everyone: bool,
) -> Vec<String> {
    let mut lines = Vec::new();
    if open_to_everyone {
        lines.push("Anyone on Inline can message it.".to_string());
    } else if let Some(summary) = sharing.summary() {
        lines.push(format!("Private: you and {summary} can message it."));
    } else {
        lines.push(
            "Private: only you can message it. Nobody else sees a composer or can mention it."
                .to_string(),
        );
    }
    lines.push(format!(
        "Share it: inline bots access grant --bot-user-id {bot_user_id} --user-id <id>  (or --space-id <id>, or add --admin)"
    ));
    lines.push("Or open the bot's chat info in the app and choose Shared With.".to_string());
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn subject(grant: &proto::SetAgentGrantInput) -> proto::access_subject::Subject {
        grant.subject.clone().unwrap().subject.unwrap()
    }

    #[test]
    fn grants_cover_people_spaces_and_admins_once() {
        use proto::AgentGrantOperation::{Configure, Invoke, Steer};
        use proto::access_subject::Subject;
        let sharing = BotSharingArgs {
            share_users: vec![7, 8, 7, 9],
            share_spaces: vec![3, 3],
            admins: vec![9],
        };
        let grants = sharing.grants(42).unwrap();
        let listed: Vec<_> = grants
            .iter()
            .map(|grant| (subject(grant), grant.operations.clone()))
            .collect();
        assert_eq!(
            listed,
            vec![
                // Named as an admin and as a plain share: the admin entry wins.
                (
                    Subject::UserId(9),
                    vec![Invoke as i32, Steer as i32, Configure as i32]
                ),
                (Subject::UserId(7), vec![Invoke as i32, Steer as i32]),
                (Subject::UserId(8), vec![Invoke as i32, Steer as i32]),
                (Subject::SpaceId(3), vec![Invoke as i32]),
            ]
        );
        assert!(grants.iter().all(|grant| grant.bot_user_id == 42));
    }

    #[test]
    fn invalid_ids_are_refused_before_anything_is_sent() {
        let sharing = BotSharingArgs {
            share_users: vec![7],
            share_spaces: vec![0],
            admins: vec![],
        };
        assert!(sharing.grants(42).is_err());
    }

    #[test]
    fn summary_says_who_can_message_and_how_to_change_it() {
        let private = access_summary_lines(42, &BotSharingArgs::default(), false);
        assert!(private[0].starts_with("Private: only you can message it."));
        assert!(private[1].contains("inline bots access grant --bot-user-id 42"));

        let shared = BotSharingArgs {
            share_users: vec![7, 8],
            share_spaces: vec![3],
            admins: vec![9],
        };
        assert_eq!(
            access_summary_lines(42, &shared, false)[0],
            "Private: you and 2 people, 1 space and 1 admin can message it."
        );
        assert_eq!(
            access_summary_lines(42, &shared, true)[0],
            "Anyone on Inline can message it."
        );
    }
}
