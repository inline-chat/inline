//! Provider-neutral question rendering and reply parsing for chat.

use super::*;

#[derive(Clone, Debug)]
pub(super) struct PendingQuestionUi {
    pub request: QuestionRequest,
    pub message_id: InlineId,
    pub token: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum QuestionActionOutcome {
    NotHandled,
    Handled,
    ProviderEpochEnded,
}

pub(super) fn question_contains_secret(request: &QuestionRequest) -> bool {
    request.questions.iter().any(|question| question.is_secret)
}

pub(super) fn empty_question_answers(request: &QuestionRequest) -> Vec<QuestionAnswer> {
    request
        .questions
        .iter()
        .map(|question| QuestionAnswer {
            question_id: question.question_id.clone(),
            answers: Vec::new(),
        })
        .collect()
}

pub(super) async fn send_question(
    bot: &InlineClient,
    chat_id: i64,
    reply_to_message_id: i64,
    provider_name: &str,
    request: &QuestionRequest,
) -> Result<Option<InlineId>, Box<dyn std::error::Error>> {
    let token = question_token(request);
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        render_question(provider_name, request),
    );
    message.reply_to_message_id = Some(InlineId::new(reply_to_message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("question-{token}"),
    )?);
    message.random_id = Some(interaction_random_id("question", &token));
    message.notification_mode = BridgeNotificationClass::ActionRequired.notification_mode();
    let actions = question_actions(request, &token)?;
    if actions.rows.is_empty() {
        Ok(send_text_with_retry(bot, message).await?.message_id)
    } else {
        Ok(
            send_interactive_text_with_retry(bot, SendInteractiveTextRequest { message, actions })
                .await?
                .message_id,
        )
    }
}

fn question_actions(
    request: &QuestionRequest,
    token: &str,
) -> Result<MessageActions, serde_json::Error> {
    let [question] = request.questions.as_slice() else {
        return Ok(MessageActions::default());
    };
    if question.options.is_empty() || question.options.len() > 5 {
        return Ok(MessageActions::default());
    }
    let mut buttons = question
        .options
        .iter()
        .enumerate()
        .map(|(index, option)| {
            Ok(MessageActionButton {
                action_id: format!("bridge_question_{index}"),
                text: truncate_utf16(&option.label, 64),
                kind: MessageActionKind::Callback {
                    data: serde_json::to_vec(&QuestionCallback {
                        version: 1,
                        token: token.to_string(),
                        choice: QuestionCallbackChoice::Option { index },
                    })?,
                },
            })
        })
        .collect::<Result<Vec<_>, serde_json::Error>>()?;
    if question.allows_other {
        buttons.push(MessageActionButton {
            action_id: "bridge_question_other".to_string(),
            text: "Other".to_string(),
            kind: MessageActionKind::Callback {
                data: serde_json::to_vec(&QuestionCallback {
                    version: 1,
                    token: token.to_string(),
                    choice: QuestionCallbackChoice::Other,
                })?,
            },
        });
    }
    buttons.push(MessageActionButton {
        action_id: "bridge_question_skip".to_string(),
        text: "Skip".to_string(),
        kind: MessageActionKind::Callback {
            data: serde_json::to_vec(&QuestionCallback {
                version: 1,
                token: token.to_string(),
                choice: QuestionCallbackChoice::Skip,
            })?,
        },
    });
    Ok(MessageActions {
        rows: buttons
            .chunks(2)
            .map(|actions| MessageActionRow {
                actions: actions.to_vec(),
            })
            .collect(),
    })
}

pub(super) async fn try_update_question_message(
    bot: &InlineClient,
    chat_id: i64,
    message_id: InlineId,
    text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id,
                text: text.to_string(),
                external_id: None,
                parse_markdown: true,
            },
            actions: MessageActions::default(),
        },
    )
    .await?;
    Ok(())
}

pub(super) async fn handle_question_action<D: AgentDriver + 'static>(
    bot: &InlineClient,
    event: &ClientEvent,
    sessions: &ProviderSessionManager<D>,
    store: &BridgeStore,
    binding: &BindingKey,
    pending_questions: &mut HashMap<i64, PendingQuestionUi>,
    owner_user_id: i64,
) -> Result<QuestionActionOutcome, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        data,
        ..
    } = event
    else {
        return Ok(QuestionActionOutcome::NotHandled);
    };
    let Ok(callback) = serde_json::from_slice::<QuestionCallback>(data) else {
        return Ok(QuestionActionOutcome::NotHandled);
    };
    let Some(pending) = pending_questions.get(&message_id.get()).cloned() else {
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some("This question is no longer active.".to_string()),
        })
        .await?;
        return Ok(QuestionActionOutcome::Handled);
    };
    if callback.version != 1 || callback.token != question_token(&pending.request) {
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some("This question is no longer active.".to_string()),
        })
        .await?;
        return Ok(QuestionActionOutcome::Handled);
    }
    if actor_user_id.get() != owner_user_id {
        bot.answer_message_action(inline_client::AnswerMessageActionRequest {
            interaction_id: *interaction_id,
            toast: Some("Only the bot owner can answer this question.".to_string()),
        })
        .await?;
        return Ok(QuestionActionOutcome::Handled);
    }
    let (answers, resolved_text, toast) = match callback.choice {
        QuestionCallbackChoice::Option { index } => {
            let Some(question) = pending.request.questions.first() else {
                return Ok(QuestionActionOutcome::Handled);
            };
            let Some(option) = question.options.get(index) else {
                bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                    interaction_id: *interaction_id,
                    toast: Some("This question is no longer active.".to_string()),
                })
                .await?;
                return Ok(QuestionActionOutcome::Handled);
            };
            (
                vec![QuestionAnswer {
                    question_id: question.question_id.clone(),
                    answers: vec![option.label.clone()],
                }],
                "Answered.",
                "Answer sent.",
            )
        }
        QuestionCallbackChoice::Other => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("Reply to this question with your answer.".to_string()),
            })
            .await?;
            return Ok(QuestionActionOutcome::Handled);
        }
        QuestionCallbackChoice::Skip => (
            empty_question_answers(&pending.request),
            "Skipped.",
            "Question skipped.",
        ),
    };
    let event_id = format!("inline-action-{}", interaction_id.get());
    let context = QuestionClaimContext {
        installation_id: binding.installation_id.clone(),
        provider_id: sessions.provider_id().clone(),
        turn_id: pending.request.turn_id.clone(),
        chat_id: chat_id.get(),
        message_id: message_id.get(),
        actor_user_id: actor_user_id.get(),
        event_id: event_id.clone(),
        now: now_seconds(),
    };
    match store.claim_question(
        &QuestionClaimLocator::CallbackToken(callback.token.clone()),
        &context,
    )? {
        QuestionClaimOutcome::Claimed(_) => {}
        QuestionClaimOutcome::Unauthorized => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("Only the bot owner can answer this question.".to_string()),
            })
            .await?;
            return Ok(QuestionActionOutcome::Handled);
        }
        QuestionClaimOutcome::Unknown
        | QuestionClaimOutcome::WrongContext
        | QuestionClaimOutcome::Expired
        | QuestionClaimOutcome::NotPending(_) => {
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some("This question is no longer active.".to_string()),
            })
            .await?;
            return Ok(QuestionActionOutcome::Handled);
        }
    }
    match sessions
        .driver()
        .resolve_question(&pending.request.request_id, answers)
        .await
    {
        Ok(()) => {
            store.finish_question(
                &pending.token,
                &event_id,
                actor_user_id.get(),
                QuestionResolution::Resolved,
                now_seconds(),
            )?;
            pending_questions.remove(&message_id.get());
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some(toast.to_string()),
            })
            .await?;
            if try_update_question_message(bot, chat_id.get(), pending.message_id, resolved_text)
                .await
                .is_ok()
            {
                store.mark_question_ui_cleared(&pending.token, now_seconds())?;
            }
        }
        Err(error) => {
            store.finish_question(
                &pending.token,
                &event_id,
                actor_user_id.get(),
                QuestionResolution::DeliveryFailed,
                now_seconds(),
            )?;
            pending_questions.remove(&message_id.get());
            eprintln!(
                "Agent question resolution failed: {}",
                safe_diagnostic(&error.to_string())
            );
            bot.answer_message_action(inline_client::AnswerMessageActionRequest {
                interaction_id: *interaction_id,
                toast: Some(
                    "The answer could not be confirmed. This question was closed.".to_string(),
                ),
            })
            .await?;
            if try_update_question_message(
                bot,
                chat_id.get(),
                pending.message_id,
                "This question is no longer active.",
            )
            .await
            .is_ok()
            {
                store.mark_question_ui_cleared(&pending.token, now_seconds())?;
            }
            return Ok(QuestionActionOutcome::ProviderEpochEnded);
        }
    }
    Ok(QuestionActionOutcome::Handled)
}

pub(super) fn render_question(provider_name: &str, request: &QuestionRequest) -> String {
    let provider = bounded_question_text(provider_name, 80);
    let provider = if provider.is_empty() {
        "The agent".to_string()
    } else {
        provider
    };
    let mut text = format!("{provider} needs your input:");
    for (index, question) in request.questions.iter().enumerate() {
        text.push_str("\n\n");
        if request.questions.len() > 1 {
            text.push_str(&format!("{}. ", index + 1));
        }
        let header = bounded_question_text(&question.header, 80);
        if !header.is_empty() {
            text.push_str(&header);
            text.push_str(" — ");
        }
        text.push_str(&bounded_question_text(&question.prompt, 300));
        for option in &question.options {
            text.push_str("\n- ");
            text.push_str(&bounded_question_text(&option.label, 80));
            if let Some(description) = option.description.as_deref() {
                let description = bounded_question_text(description, 160);
                if !description.is_empty() {
                    text.push_str(" — ");
                    text.push_str(&description);
                }
            }
        }
        if question.allows_other && !question.options.is_empty() {
            text.push_str("\n- Another answer");
        }
    }
    if request.questions.len() == 1 {
        text.push_str("\n\nReply to this message with your answer, or use Skip.");
    } else {
        text.push_str(
            "\n\nReply with one answer per line, in the same order. Reply `skip all` to skip.",
        );
    }
    if let Some(milliseconds) = request.auto_resolution_ms {
        let seconds = milliseconds.div_ceil(1_000);
        text.push_str(&format!(" This may auto-resolve in about {seconds}s."));
    }
    text
}

pub(super) fn parse_question_answers(
    request: &QuestionRequest,
    input: &str,
) -> Result<Vec<QuestionAnswer>, &'static str> {
    if question_contains_secret(request) {
        return Err("Secret answers cannot be sent through Inline.");
    }
    if input.trim().eq_ignore_ascii_case("skip all")
        && !request.questions.iter().any(|question| {
            question
                .options
                .iter()
                .any(|option| option.label.eq_ignore_ascii_case("skip all"))
        })
    {
        return Ok(empty_question_answers(request));
    }
    let lines = input
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    if lines.is_empty() {
        return Err("Reply with an answer.");
    }
    if request.questions.len() > 1 && lines.len() != request.questions.len() {
        return Err("Reply with one answer per line, in the same order.");
    }
    let raw_answers = if request.questions.len() == 1 {
        vec![input.trim()]
    } else {
        lines
    };
    request
        .questions
        .iter()
        .zip(raw_answers)
        .enumerate()
        .map(|(index, (question, answer))| {
            let answer = strip_answer_prefix(answer, index + 1);
            let answer = normalized_answer(question, answer)?;
            Ok(QuestionAnswer {
                question_id: question.question_id.clone(),
                answers: vec![answer],
            })
        })
        .collect()
}

fn normalized_answer(question: &Question, answer: &str) -> Result<String, &'static str> {
    let answer = bounded_question_text(answer, 500);
    if answer.is_empty() {
        return Err("Every question needs an answer.");
    }
    if let Ok(index) = answer.parse::<usize>()
        && let Some(option) = index
            .checked_sub(1)
            .and_then(|index| question.options.get(index))
    {
        return Ok(option.label.clone());
    }
    if let Some(option) = question
        .options
        .iter()
        .find(|option| option.label.eq_ignore_ascii_case(&answer))
    {
        return Ok(option.label.clone());
    }
    if question.options.is_empty() || question.allows_other {
        return Ok(format!("user_note: {answer}"));
    }
    Err("Reply with one of the listed option labels.")
}

fn strip_answer_prefix(answer: &str, expected_index: usize) -> &str {
    let answer = answer.trim();
    for separator in [". ", ": ", ") "] {
        let prefix = format!("{expected_index}{separator}");
        if let Some(answer) = answer.strip_prefix(&prefix) {
            return answer.trim();
        }
    }
    answer
}

fn bounded_question_text(value: &str, maximum: usize) -> String {
    let value = value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate(&value, maximum)
}

pub(super) fn question_token(request: &QuestionRequest) -> String {
    let mut digest = Sha256::new();
    digest.update(request.turn_id.as_str().as_bytes());
    digest.update([0]);
    digest.update(request.request_id.as_bytes());
    digest.finalize()[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn question_request() -> QuestionRequest {
        QuestionRequest {
            request_id: "request-1".to_string(),
            turn_id: inline_agent_bridge::TurnId::new("turn-1").expect("turn"),
            questions: vec![
                Question {
                    question_id: "target".to_string(),
                    header: "Target".to_string(),
                    prompt: "Which target?".to_string(),
                    options: vec![
                        inline_agent_bridge::QuestionOption {
                            label: "Core".to_string(),
                            description: Some("Inspect core".to_string()),
                        },
                        inline_agent_bridge::QuestionOption {
                            label: "TUI".to_string(),
                            description: Some("Inspect TUI".to_string()),
                        },
                    ],
                    allows_other: false,
                    is_secret: false,
                },
                Question {
                    question_id: "details".to_string(),
                    header: "Details".to_string(),
                    prompt: "Anything else?".to_string(),
                    options: Vec::new(),
                    allows_other: true,
                    is_secret: false,
                },
            ],
            auto_resolution_ms: Some(60_000),
        }
    }

    #[test]
    fn renders_bounded_chat_native_question_copy() {
        let text = render_question("Codex", &question_request());
        assert!(text.starts_with("Codex needs your input:"));
        assert!(text.contains("1. Target — Which target?"));
        assert!(text.contains("- Core — Inspect core"));
        assert!(text.contains("one answer per line"));
        assert!(text.contains("about 60s"));
    }

    #[test]
    fn parses_ordered_option_and_free_form_answers() {
        let answers = parse_question_answers(&question_request(), "1. tui\n2. Include snapshots")
            .expect("answers");
        assert_eq!(answers[0].answers, ["TUI"]);
        assert_eq!(answers[1].answers, ["user_note: Include snapshots"]);
    }

    #[test]
    fn parses_numeric_option_selection() {
        let mut request = question_request();
        request.questions.truncate(1);
        let answers = parse_question_answers(&request, "2").expect("answers");
        assert_eq!(answers[0].answers, ["TUI"]);
    }

    #[test]
    fn explicit_skip_declines_every_question() {
        let answers = parse_question_answers(&question_request(), "skip all").expect("skip");
        assert_eq!(answers, empty_question_answers(&question_request()));
    }

    #[test]
    fn rejects_unknown_fixed_option_and_secret_input() {
        let mut request = question_request();
        request.questions.truncate(1);
        assert_eq!(
            parse_question_answers(&request, "Web"),
            Err("Reply with one of the listed option labels.")
        );
        request.questions[0].is_secret = true;
        assert_eq!(
            parse_question_answers(&request, "secret"),
            Err("Secret answers cannot be sent through Inline.")
        );
    }

    #[test]
    fn single_choice_questions_use_bounded_native_actions() {
        let mut request = question_request();
        request.questions.truncate(1);
        request.questions[0].allows_other = true;

        let actions = question_actions(&request, "token").expect("question actions");

        assert_eq!(actions.rows.len(), 2);
        assert_eq!(actions.rows[0].actions[0].text, "Core");
        assert_eq!(actions.rows[0].actions[1].text, "TUI");
        assert_eq!(actions.rows[1].actions[0].text, "Other");
        assert_eq!(actions.rows[1].actions[1].text, "Skip");
        assert!(actions.rows.iter().all(|row| row.actions.len() <= 2));
    }
}
