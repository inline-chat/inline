use inline_protocol::proto;
use serde::Serialize;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MessagePage {
    pub fetched_count: usize,
    pub returned_count: usize,
    pub next_offset_id: Option<i64>,
    pub filters_applied_to_page: bool,
}

impl MessagePage {
    pub fn new(messages: &[proto::Message], filters_applied_to_page: bool) -> Self {
        Self {
            fetched_count: messages.len(),
            returned_count: messages.len(),
            // Keep the cursor even when local filters remove every message.
            next_offset_id: messages
                .iter()
                .map(|message| message.id)
                .filter(|id| *id > 0)
                .min(),
            filters_applied_to_page,
        }
    }
}

#[derive(Serialize)]
pub(crate) struct MessagePageOutput<T> {
    #[serde(flatten)]
    pub payload: T,
    pub page: MessagePage,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filtered_empty_page_retains_the_scanned_cursor_and_existing_fields() {
        let mut payload = proto::SearchMessagesResult {
            messages: vec![
                proto::Message {
                    id: 20,
                    ..Default::default()
                },
                proto::Message {
                    id: 10,
                    ..Default::default()
                },
            ],
        };
        let mut page = MessagePage::new(&payload.messages, true);
        payload.messages.clear();
        page.returned_count = 0;
        let json = serde_json::to_value(MessagePageOutput { payload, page }).unwrap();
        assert_eq!(json["messages"], serde_json::json!([]));
        assert_eq!(json["page"]["nextOffsetId"], 10);
        assert_eq!(json["page"]["fetchedCount"], 2);
        assert_eq!(json["page"]["returnedCount"], 0);
        assert!(json["page"]["filtersAppliedToPage"].as_bool().unwrap());
    }
}
