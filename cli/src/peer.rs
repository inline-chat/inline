use crate::errors::CliError;
use crate::validation::validate_positive_id_arg;
use inline_protocol::proto;
use inline_sdk::api::PeerId;

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub(crate) enum PeerKey {
    Chat(i64),
    User(i64),
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub(crate) struct MessageKey {
    pub(crate) peer: PeerKey,
    pub(crate) id: i64,
}

pub(crate) fn input_peer_from_args(
    chat_id: Option<i64>,
    user_id: Option<i64>,
) -> Result<proto::InputPeer, Box<dyn std::error::Error>> {
    match (chat_id, user_id) {
        (Some(_), Some(_)) => {
            Err(CliError::invalid_args("Provide only one of --chat-id or --user-id.").into())
        }
        (Some(chat_id), None) => {
            let chat_id = validate_positive_id_arg("--chat-id", chat_id)?;
            Ok(proto::InputPeer {
                r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
                    chat_id,
                })),
            })
        }
        (None, Some(user_id)) => {
            let user_id = validate_positive_id_arg("--user-id", user_id)?;
            Ok(proto::InputPeer {
                r#type: Some(proto::input_peer::Type::User(proto::InputPeerUser {
                    user_id,
                })),
            })
        }
        (None, None) => Err(CliError::missing_peer().into()),
    }
}

pub(crate) fn api_peer_from_args(
    chat_id: Option<i64>,
    user_id: Option<i64>,
) -> Result<PeerId, Box<dyn std::error::Error>> {
    match (chat_id, user_id) {
        (Some(_), Some(_)) => {
            Err(CliError::invalid_args("Provide only one of --chat-id or --user-id.").into())
        }
        (Some(chat_id), None) => {
            let chat_id = validate_positive_id_arg("--chat-id", chat_id)?;
            Ok(PeerId::thread(chat_id))
        }
        (None, Some(user_id)) => {
            let user_id = validate_positive_id_arg("--user-id", user_id)?;
            Ok(PeerId::user(user_id))
        }
        (None, None) => Err(CliError::missing_peer().into()),
    }
}

pub(crate) fn peer_key_from_peer(peer: &proto::Peer) -> Option<PeerKey> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(PeerKey::Chat(chat.chat_id)),
        Some(proto::peer::Type::User(user)) => Some(PeerKey::User(user.user_id)),
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_peer_from_chat_id() {
        let peer = input_peer_from_args(Some(123), None).unwrap();

        match peer.r#type {
            Some(proto::input_peer::Type::Chat(chat)) => assert_eq!(chat.chat_id, 123),
            other => panic!("expected chat peer, got {other:?}"),
        }
    }

    #[test]
    fn input_peer_conflicting_args_are_structured() {
        let err = input_peer_from_args(Some(1), Some(2)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--chat-id"));
        assert!(cli_err.message.contains("--user-id"));
    }

    #[test]
    fn input_peer_rejects_non_positive_ids() {
        let err = input_peer_from_args(Some(0), None).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--chat-id"));

        let err = input_peer_from_args(None, Some(-1)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--user-id"));
    }

    #[test]
    fn api_peer_from_chat_and_user_ids() {
        assert_eq!(
            api_peer_from_args(Some(123), None).unwrap(),
            PeerId::thread(123)
        );
        assert_eq!(
            api_peer_from_args(None, Some(456)).unwrap(),
            PeerId::user(456)
        );
    }

    #[test]
    fn api_peer_rejects_non_positive_ids() {
        let err = api_peer_from_args(Some(0), None).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--chat-id"));

        let err = api_peer_from_args(None, Some(-1)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--user-id"));
    }

    #[test]
    fn peer_key_from_chat_peer() {
        let peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 42 })),
        };

        assert_eq!(peer_key_from_peer(&peer), Some(PeerKey::Chat(42)));
    }
}
