use inline_protocol::proto;
use serde::Serialize;

use crate::errors::CliError;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ForwardReceipt {
    pub from_peer: proto::InputPeer,
    pub to_peer: proto::InputPeer,
    pub completed: bool,
    pub forwarded: Vec<ForwardedMessage>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ForwardedMessage {
    source_message_id: String,
    destination_message_id: String,
}

#[derive(Serialize)]
pub(crate) struct ForwardOutput<'a> {
    #[serde(flatten)]
    pub payload: &'a proto::ForwardMessagesResult,
    #[serde(flatten)]
    pub receipt: &'a ForwardReceipt,
}

pub(crate) fn build_forward_receipt(
    from_peer: proto::InputPeer,
    to_peer: proto::InputPeer,
    source_ids: &[i64],
    payload: &proto::ForwardMessagesResult,
) -> Result<ForwardReceipt, CliError> {
    // The server emits one updateMessageId per source occurrence, in request order.
    let destination_ids: Vec<_> = payload
        .updates
        .iter()
        .filter_map(|update| match &update.update {
            Some(proto::update::Update::UpdateMessageId(receipt)) => Some(receipt.message_id),
            _ => None,
        })
        .collect();
    if source_ids.len() != destination_ids.len() || destination_ids.iter().any(|id| *id <= 0) {
        return Err(CliError {
            code: "invalid_forward_receipt",
            message: "Forwarding returned an incomplete receipt".into(),
            hint: Some("Messages may already have been delivered. Inspect the destination before retrying; forwarding is not idempotent.".into()),
            examples: Vec::new(),
        });
    }
    Ok(ForwardReceipt {
        from_peer,
        to_peer,
        completed: true,
        forwarded: source_ids
            .iter()
            .zip(destination_ids)
            .map(|(source, destination)| ForwardedMessage {
                source_message_id: source.to_string(),
                destination_message_id: destination.to_string(),
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(ids: &[i64]) -> proto::ForwardMessagesResult {
        proto::ForwardMessagesResult {
            updates: ids
                .iter()
                .map(|id| proto::Update {
                    update: Some(proto::update::Update::UpdateMessageId(
                        proto::UpdateMessageId {
                            message_id: *id,
                            ..Default::default()
                        },
                    )),
                    ..Default::default()
                })
                .collect(),
        }
    }

    #[test]
    fn maps_duplicate_sources_in_request_order_and_preserves_raw_output() {
        let payload = result(&[100, 101, 102]);
        let receipt =
            build_forward_receipt(Default::default(), Default::default(), &[9, 3, 9], &payload)
                .unwrap();
        let json = serde_json::to_value(ForwardOutput {
            payload: &payload,
            receipt: &receipt,
        })
        .unwrap();
        assert_eq!(
            json["updates"],
            serde_json::to_value(&payload).unwrap()["updates"]
        );
        assert_eq!(json["forwarded"][0]["sourceMessageId"], "9");
        assert_eq!(json["forwarded"][1]["destinationMessageId"], "101");
        assert_eq!(json["forwarded"][2]["sourceMessageId"], "9");
        assert!(
            serde_json::to_value(&receipt)
                .unwrap()
                .get("updates")
                .is_none()
        );
    }

    #[test]
    fn refuses_unverifiable_receipts_after_a_write() {
        for ids in [&[100][..], &[100, 0][..], &[100, 101, 102][..]] {
            let error = build_forward_receipt(
                Default::default(),
                Default::default(),
                &[9, 3],
                &result(ids),
            )
            .err()
            .unwrap();
            assert_eq!(error.code, "invalid_forward_receipt");
            assert!(error.hint.unwrap().contains("before retrying"));
        }
    }
}
