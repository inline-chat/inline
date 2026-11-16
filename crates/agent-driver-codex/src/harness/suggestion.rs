//! Composer predictions, the way the Codex app makes them: after a user's turn
//! completes, one `thread/sample` on an ephemeral fork of the thread (same
//! model and context, warm prompt cache, MCP off) predicts the user's next
//! message. Codex's own prompt lives on OpenAI's servers; this one is ours.

use inline_agent_bridge::harness::{Event, TurnPhase};
use inline_agent_bridge::{TurnId, TurnOutcome};
use serde_json::{Value, json};

use super::delivery::Request;

const PROMPT: &str = "\
Predict the next message the user will send in this conversation, written as they would type it. \
Not what you think they should do: what they were about to type themselves. \
Examples: you fixed a bug they asked about and tests were part of the ask -> \"run the tests\"; \
you finished a change -> \"try it\" or \"commit this\"; you offered options -> the option they would pick; \
you asked whether to continue -> \"yes\". Be specific. \
Never suggest thanks or praise, questions, your own voice (\"I'll\", \"Let me\"), ideas they did not raise, \
or more than one sentence. Use null when the next step is not obvious, after an error or a misunderstanding, \
or when the topic is sensitive. Match their language and style, 2 to 12 words. Do not use tools.";

const SCHEMA: &str = r#"{"type":"object","properties":{"suggestion":{"type":["string","null"]}},"required":["suggestion"],"additionalProperties":false}"#;

/// The turn to predict after: a completed turn that took Inline input. Turns
/// Codex starts itself (compaction, background work) and stopped or failed
/// ones get nothing, like the Codex app.
pub(crate) fn turn_to_follow(events: &[Event]) -> Option<TurnId> {
    events.iter().find_map(|event| match event {
        Event::Turn {
            turn,
            phase:
                TurnPhase::Completed {
                    outcome: TurnOutcome::Completed,
                    inputs_consumed,
                    ..
                },
        } if !inputs_consumed.is_empty() => Some(turn.clone()),
        _ => None,
    })
}

pub(crate) fn request(thread: &str, turn: &TurnId) -> Request {
    Request {
        method: "thread/sample",
        params: json!({
            "threadId": thread,
            "expectedTurnId": turn.as_str(),
            "prompt": format!("{PROMPT}  Return only JSON matching this schema: {SCHEMA}."),
            // Applied by Codex only when it keeps the prompt cache.
            "effort": "low",
            "disableMcp": true,
        }),
    }
}

/// The suggestion in a `thread/sample` response, if it gave one.
pub(crate) fn parse(response: &Value) -> Option<String> {
    let text = response.get("text")?.as_str()?;
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    let value: Value = serde_json::from_str(text.get(start..=end)?).ok()?;
    let suggestion = value.get("suggestion")?.as_str()?.trim();
    (!suggestion.is_empty()).then(|| suggestion.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::harness::InputId;

    fn completed(outcome: TurnOutcome, inputs: usize) -> Event {
        Event::Turn {
            turn: TurnId::new("turn-1").unwrap(),
            phase: TurnPhase::Completed {
                outcome,
                inputs_consumed: (0..inputs)
                    .map(|index| InputId::new(format!("input-{index}")).unwrap())
                    .collect(),
                error: None,
                duration_ms: None,
            },
        }
    }

    #[test]
    fn follows_only_completed_turns_that_took_input() {
        assert_eq!(
            turn_to_follow(&[completed(TurnOutcome::Completed, 1)]),
            Some(TurnId::new("turn-1").unwrap())
        );
        assert_eq!(
            turn_to_follow(&[completed(TurnOutcome::Completed, 0)]),
            None
        );
        assert_eq!(
            turn_to_follow(&[completed(TurnOutcome::Interrupted, 1)]),
            None
        );
        assert_eq!(turn_to_follow(&[completed(TurnOutcome::Failed, 1)]), None);
    }

    #[test]
    fn request_samples_the_finished_turn_without_mcp() {
        let request = request("thread-1", &TurnId::new("turn-9").unwrap());
        assert_eq!(request.method, "thread/sample");
        assert_eq!(request.params["threadId"], "thread-1");
        assert_eq!(request.params["expectedTurnId"], "turn-9");
        assert_eq!(request.params["disableMcp"], true);
        assert!(
            request.params["prompt"]
                .as_str()
                .unwrap()
                .contains("Return only JSON")
        );
    }

    #[test]
    fn parses_the_suggestion_or_nothing() {
        assert_eq!(
            parse(&json!({"text": "{\"suggestion\": \" run the tests \"}"})),
            Some("run the tests".to_owned())
        );
        assert_eq!(
            parse(&json!({"text": "```json\n{\"suggestion\":\"yes\"}\n```"})),
            Some("yes".to_owned())
        );
        assert_eq!(parse(&json!({"text": "{\"suggestion\": null}"})), None);
        assert_eq!(parse(&json!({"text": "{\"suggestion\": \"\"}"})), None);
        assert_eq!(parse(&json!({"text": null})), None);
        assert_eq!(parse(&json!({"text": "run the tests"})), None);
    }
}
