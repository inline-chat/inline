use std::collections::{BTreeMap, HashMap, HashSet};

use agent_client_protocol::schema::v1 as acp;
use inline_agent_bridge::{
    DriverError, DriverResult, Question, QuestionAnswer, QuestionOption, QuestionRequest, TurnId,
};

const MAX_QUESTIONS: usize = 4;
const MAX_QUESTION_ID_BYTES: usize = 128;
const MAX_OPTIONS: usize = 16;
const MAX_HEADER_CHARS: usize = 80;
const MAX_PROMPT_CHARS: usize = 2_000;
const MAX_OPTION_LABEL_CHARS: usize = 160;
const MAX_OPTION_VALUE_BYTES: usize = 512;
const MAX_OPTION_DESCRIPTION_CHARS: usize = 400;
const MAX_ANSWER_CHARS: usize = 2_000;
const CUSTOM_ANSWER_META_KEY: &str = "_askUserQuestionCustomAnswer";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FieldKind {
    String,
    StringArray,
}

struct NormalizedProperty {
    kind: FieldKind,
    title: Option<String>,
    description: Option<String>,
    options: Vec<acp::EnumOption>,
}

#[derive(Debug)]
pub(crate) struct ElicitationField {
    question_id: String,
    kind: FieldKind,
    choices: HashMap<String, String>,
    custom_field: Option<String>,
    required: bool,
}

#[derive(Debug)]
pub(crate) struct NormalizedElicitation {
    pub request: QuestionRequest,
    pub fields: Vec<ElicitationField>,
}

pub(crate) fn normalize_form(
    request_id: String,
    turn_id: TurnId,
    message: &str,
    schema: acp::ElicitationSchema,
) -> DriverResult<NormalizedElicitation> {
    let property_count = schema.properties.len();
    if property_count == 0 || property_count > MAX_QUESTIONS * 2 {
        return Err(protocol_error(
            "ACP elicitation contains an unsupported number of fields",
        ));
    }
    let required = schema
        .required
        .unwrap_or_default()
        .into_iter()
        .collect::<HashSet<_>>();
    if !required
        .iter()
        .all(|field| schema.properties.contains_key(field))
    {
        return Err(protocol_error("ACP elicitation requires an unknown field"));
    }
    let custom_fields = custom_field_pairs(&schema.properties);
    let mut fields = Vec::new();
    let mut questions = Vec::new();

    for (question_id, property) in schema.properties {
        validate_id(&question_id)?;
        if custom_fields.values().any(|custom| custom == &question_id) {
            if required.contains(&question_id) {
                return Err(protocol_error(
                    "ACP custom-answer companion fields must be optional",
                ));
            }
            continue;
        }
        let custom_field = custom_fields.get(&question_id).cloned();
        let is_required = required.contains(&question_id);
        let NormalizedProperty {
            kind,
            title,
            description,
            options,
        } = normalize_property(property)?;
        let allows_multiple = kind == FieldKind::StringArray;
        let prompt = bounded_text(
            description
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(message),
            MAX_PROMPT_CHARS,
        );
        if prompt.is_empty() {
            return Err(protocol_error("ACP elicitation question has no prompt"));
        }
        if options.len() > MAX_OPTIONS {
            return Err(protocol_error("ACP elicitation has too many options"));
        }
        let mut labels = HashSet::new();
        let mut choices = HashMap::new();
        let options = options
            .into_iter()
            .map(|option| {
                validate_option_value(&option.value)?;
                let label = bounded_text(&option.title, MAX_OPTION_LABEL_CHARS);
                if label.is_empty() || !labels.insert(label.to_ascii_lowercase()) {
                    return Err(protocol_error(
                        "ACP elicitation has empty or ambiguous option labels",
                    ));
                }
                choices.insert(label.clone(), option.value);
                Ok(QuestionOption {
                    label,
                    description: option
                        .description
                        .as_deref()
                        .map(|value| bounded_text(value, MAX_OPTION_DESCRIPTION_CHARS))
                        .filter(|value| !value.is_empty()),
                })
            })
            .collect::<DriverResult<Vec<_>>>()?;
        let allows_other = custom_field.is_some() && !is_required;
        fields.push(ElicitationField {
            question_id: question_id.clone(),
            kind,
            choices,
            custom_field,
            required: is_required,
        });
        questions.push(Question {
            question_id,
            header: bounded_text(title.as_deref().unwrap_or_default(), MAX_HEADER_CHARS),
            prompt,
            options,
            allows_multiple,
            allows_other,
            is_secret: false,
        });
    }

    if questions.is_empty() || questions.len() > MAX_QUESTIONS {
        return Err(protocol_error(
            "ACP elicitation must contain between one and four supported questions",
        ));
    }
    if schema_property_count(&fields) != property_count {
        // Every property must either be rendered as a question or be the
        // optional companion free-text field for one rendered question.
        return Err(protocol_error(
            "ACP elicitation contains unsupported fields",
        ));
    }

    Ok(NormalizedElicitation {
        request: QuestionRequest {
            request_id,
            turn_id,
            questions,
            auto_resolution_ms: None,
        },
        fields,
    })
}

fn schema_property_count(fields: &[ElicitationField]) -> usize {
    fields
        .iter()
        .map(|field| 1 + usize::from(field.custom_field.is_some()))
        .sum()
}

fn custom_field_pairs(
    properties: &BTreeMap<String, acp::ElicitationPropertySchema>,
) -> HashMap<String, String> {
    properties
        .iter()
        .filter_map(|(key, property)| {
            let acp::ElicitationPropertySchema::String(custom) = property else {
                return None;
            };
            let marker = custom
                .meta
                .as_ref()?
                .get(CUSTOM_ANSWER_META_KEY)?
                .as_object()?;
            let base = marker.get("questionId")?.as_str()?;
            if marker
                .get("isCustomAnswer")
                .and_then(serde_json::Value::as_bool)
                != Some(true)
                || key != &format!("{base}_custom")
            {
                return None;
            }
            let base_property = properties.get(base)?;
            let base_has_choices = match base_property {
                acp::ElicitationPropertySchema::String(base) => {
                    base.one_of
                        .as_ref()
                        .is_some_and(|values| !values.is_empty())
                        || base
                            .enum_values
                            .as_ref()
                            .is_some_and(|values| !values.is_empty())
                }
                acp::ElicitationPropertySchema::Array(_) => true,
                _ => false,
            };
            let is_plain_string = custom.one_of.is_none()
                && custom.enum_values.is_none()
                && custom.min_length.is_none()
                && custom.max_length.is_none()
                && custom.pattern.is_none()
                && custom.format.is_none();
            (base_has_choices && is_plain_string).then(|| (base.to_string(), key.to_string()))
        })
        .collect()
}

fn normalize_property(
    property: acp::ElicitationPropertySchema,
) -> DriverResult<NormalizedProperty> {
    match property {
        acp::ElicitationPropertySchema::String(property) => {
            if property.min_length.is_some()
                || property.max_length.is_some()
                || property.pattern.is_some()
                || property.format.is_some()
            {
                return Err(protocol_error(
                    "ACP constrained free-text elicitation is unsupported",
                ));
            }
            let options = match (property.one_of, property.enum_values) {
                (Some(_), Some(_)) => {
                    return Err(protocol_error(
                        "ACP elicitation cannot combine oneOf and enum",
                    ));
                }
                (Some(options), None) => options,
                (None, Some(values)) => values
                    .into_iter()
                    .map(|value| acp::EnumOption::new(value.clone(), value))
                    .collect(),
                (None, None) => {
                    return Err(protocol_error(
                        "ACP free-text elicitation is unsupported without a secret-aware field contract",
                    ));
                }
            };
            Ok(NormalizedProperty {
                kind: FieldKind::String,
                title: property.title,
                description: property.description,
                options,
            })
        }
        acp::ElicitationPropertySchema::Array(property) => {
            if property.min_items.is_some() || property.max_items.is_some() {
                return Err(protocol_error(
                    "ACP constrained multi-select elicitation is unsupported",
                ));
            }
            let options = match property.items {
                acp::MultiSelectItems::String(items) => items
                    .values
                    .into_iter()
                    .map(|value| acp::EnumOption::new(value.clone(), value))
                    .collect(),
                acp::MultiSelectItems::Titled(items) => items.options,
                _ => {
                    return Err(protocol_error(
                        "ACP elicitation has unsupported multi-select items",
                    ));
                }
            };
            if options.is_empty() {
                return Err(protocol_error(
                    "ACP multi-select elicitation has no options",
                ));
            }
            Ok(NormalizedProperty {
                kind: FieldKind::StringArray,
                title: property.title,
                description: property.description,
                options,
            })
        }
        _ => Err(protocol_error("ACP elicitation field type is unsupported")),
    }
}

fn validate_id(value: &str) -> DriverResult<()> {
    if value.trim().is_empty()
        || value.len() > MAX_QUESTION_ID_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(protocol_error(
            "ACP elicitation has an invalid field identity",
        ));
    }
    Ok(())
}

fn validate_option_value(value: &str) -> DriverResult<()> {
    if value.trim().is_empty()
        || value.len() > MAX_OPTION_VALUE_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(protocol_error(
            "ACP elicitation has an invalid option value",
        ));
    }
    Ok(())
}

pub(crate) fn answer_response(
    fields: &[ElicitationField],
    answers: Vec<QuestionAnswer>,
) -> DriverResult<acp::CreateElicitationResponse> {
    let answer_ids = answers
        .iter()
        .map(|answer| answer.question_id.as_str())
        .collect::<HashSet<_>>();
    if answer_ids.len() != answers.len()
        || answer_ids.len() != fields.len()
        || !fields
            .iter()
            .all(|field| answer_ids.contains(field.question_id.as_str()))
    {
        return Err(DriverError::Rejected(
            "ACP elicitation received an incomplete or invalid answer set".to_string(),
        ));
    }
    if answers.iter().all(|answer| answer.answers.is_empty()) {
        return Ok(acp::CreateElicitationResponse::new(
            acp::ElicitationAction::Decline,
        ));
    }

    let answers = answers
        .into_iter()
        .map(|answer| (answer.question_id, answer.answers))
        .collect::<HashMap<_, _>>();
    let mut content = BTreeMap::new();
    for field in fields {
        let values = answers
            .get(&field.question_id)
            .expect("validated elicitation answer disappeared");
        if values.is_empty() {
            if field.required {
                return Err(DriverError::Rejected(
                    "ACP elicitation is missing a required answer".to_string(),
                ));
            }
            continue;
        }
        if field.kind == FieldKind::String && values.len() != 1 {
            return Err(DriverError::Rejected(
                "ACP single-select elicitation received multiple answers".to_string(),
            ));
        }
        let mut selected = Vec::new();
        let mut custom = None;
        for value in values {
            let value = bounded_text(value, MAX_ANSWER_CHARS);
            if value.is_empty() {
                return Err(DriverError::Rejected(
                    "ACP elicitation answer is empty".to_string(),
                ));
            }
            if let Some(provider_value) = choice_value(&field.choices, &value) {
                selected.push(provider_value.to_string());
                continue;
            }
            let free_form = value.strip_prefix("user_note: ").unwrap_or(&value).trim();
            if free_form.is_empty() {
                return Err(DriverError::Rejected(
                    "ACP elicitation answer is empty".to_string(),
                ));
            }
            if field.custom_field.is_some()
                && !field.required
                && custom.is_none()
                && selected.is_empty()
            {
                custom = Some(free_form.to_string());
            } else {
                return Err(DriverError::Rejected(
                    "ACP elicitation answer was not one of the offered choices".to_string(),
                ));
            }
        }
        if custom.is_some() && !selected.is_empty() {
            return Err(DriverError::Rejected(
                "ACP elicitation cannot mix choices and a custom answer".to_string(),
            ));
        }
        if let Some(custom) = custom {
            let custom_field = field
                .custom_field
                .as_ref()
                .expect("custom elicitation value has no field");
            content.insert(
                custom_field.clone(),
                acp::ElicitationContentValue::String(custom),
            );
            continue;
        }
        match field.kind {
            FieldKind::String if selected.len() == 1 => {
                content.insert(
                    field.question_id.clone(),
                    acp::ElicitationContentValue::String(selected.remove(0)),
                );
            }
            FieldKind::StringArray => {
                content.insert(
                    field.question_id.clone(),
                    acp::ElicitationContentValue::StringArray(selected),
                );
            }
            FieldKind::String => {
                return Err(DriverError::Rejected(
                    "ACP single-select elicitation received multiple answers".to_string(),
                ));
            }
        }
    }
    Ok(acp::CreateElicitationResponse::new(
        acp::ElicitationAcceptAction::new().content(content),
    ))
}

fn choice_value<'a>(choices: &'a HashMap<String, String>, label: &str) -> Option<&'a str> {
    choices
        .iter()
        .find(|(candidate, _)| candidate.eq_ignore_ascii_case(label))
        .map(|(_, value)| value.as_str())
}

fn bounded_text(value: &str, maximum: usize) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(maximum)
        .collect()
}

fn protocol_error(message: &str) -> DriverError {
    DriverError::Protocol(message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude_form() -> acp::ElicitationSchema {
        let custom_meta = serde_json::json!({
            CUSTOM_ANSWER_META_KEY: {
                "questionId": "question_0",
                "isCustomAnswer": true,
            }
        })
        .as_object()
        .expect("custom answer metadata")
        .clone();
        acp::ElicitationSchema::new()
            .property(
                "question_0",
                acp::StringPropertySchema::new()
                    .title("Target")
                    .one_of(vec![
                        acp::EnumOption::new("core", "Core").description("Inspect core"),
                        acp::EnumOption::new("cli", "CLI"),
                    ]),
                false,
            )
            .property(
                "question_0_custom",
                acp::StringPropertySchema::new()
                    .title("Other")
                    .meta(custom_meta),
                false,
            )
    }

    #[test]
    fn maps_claude_question_and_preserves_provider_values() {
        let normalized = normalize_form(
            "request-1".to_string(),
            TurnId::new("turn-1").expect("turn"),
            "Which target?",
            claude_form(),
        )
        .expect("normalize Claude form");
        assert_eq!(normalized.request.questions.len(), 1);
        assert_eq!(normalized.request.questions[0].header, "Target");
        assert_eq!(normalized.request.questions[0].prompt, "Which target?");
        assert!(!normalized.request.questions[0].allows_multiple);
        assert!(normalized.request.questions[0].allows_other);

        let response = answer_response(
            &normalized.fields,
            vec![QuestionAnswer {
                question_id: "question_0".to_string(),
                answers: vec!["Core".to_string()],
            }],
        )
        .expect("answer Claude form");
        let acp::ElicitationAction::Accept(accepted) = response.action else {
            panic!("expected accepted response")
        };
        assert_eq!(
            accepted
                .content
                .expect("accepted content")
                .get("question_0"),
            Some(&acp::ElicitationContentValue::String("core".to_string()))
        );
    }

    #[test]
    fn routes_free_form_to_claude_custom_field_and_empty_answers_decline() {
        let normalized = normalize_form(
            "request-1".to_string(),
            TurnId::new("turn-1").expect("turn"),
            "Which target?",
            claude_form(),
        )
        .expect("normalize Claude form");
        let response = answer_response(
            &normalized.fields,
            vec![QuestionAnswer {
                question_id: "question_0".to_string(),
                answers: vec!["user_note: Landing".to_string()],
            }],
        )
        .expect("answer custom field");
        let acp::ElicitationAction::Accept(accepted) = response.action else {
            panic!("expected accepted response")
        };
        assert_eq!(
            accepted
                .content
                .expect("accepted content")
                .get("question_0_custom"),
            Some(&acp::ElicitationContentValue::String("Landing".to_string()))
        );

        let declined = answer_response(
            &normalized.fields,
            vec![QuestionAnswer {
                question_id: "question_0".to_string(),
                answers: Vec::new(),
            }],
        )
        .expect("decline form");
        assert!(matches!(declined.action, acp::ElicitationAction::Decline));
    }

    #[test]
    fn maps_claude_multi_select_and_preserves_every_provider_value() {
        let mut schema = claude_form();
        schema.properties.insert(
            "question_0".to_string(),
            acp::MultiSelectPropertySchema::titled(vec![
                acp::EnumOption::new("core", "Core"),
                acp::EnumOption::new("cli", "CLI"),
            ])
            .into(),
        );
        let normalized = normalize_form(
            "request-multi".to_string(),
            TurnId::new("turn-multi").expect("turn"),
            "Which targets?",
            schema,
        )
        .expect("normalize multi-select");
        assert!(normalized.request.questions[0].allows_multiple);
        assert!(normalized.request.questions[0].allows_other);

        let response = answer_response(
            &normalized.fields,
            vec![QuestionAnswer {
                question_id: "question_0".to_string(),
                answers: vec!["Core".to_string(), "CLI".to_string()],
            }],
        )
        .expect("answer multi-select");
        let acp::ElicitationAction::Accept(accepted) = response.action else {
            panic!("expected accepted response")
        };
        assert_eq!(
            accepted
                .content
                .expect("accepted content")
                .get("question_0"),
            Some(&acp::ElicitationContentValue::StringArray(vec![
                "core".to_string(),
                "cli".to_string(),
            ]))
        );
    }

    #[test]
    fn rejects_unrepresentable_or_ambiguous_forms() {
        let boolean = acp::ElicitationSchema::new().boolean("enabled", true);
        assert!(
            normalize_form(
                "request-1".to_string(),
                TurnId::new("turn-1").expect("turn"),
                "Enable?",
                boolean,
            )
            .is_err()
        );

        let duplicate_labels = acp::ElicitationSchema::new().property(
            "target",
            acp::StringPropertySchema::new().one_of(vec![
                acp::EnumOption::new("one", "Same"),
                acp::EnumOption::new("two", "same"),
            ]),
            true,
        );
        assert!(
            normalize_form(
                "request-2".to_string(),
                TurnId::new("turn-2").expect("turn"),
                "Target?",
                duplicate_labels,
            )
            .is_err()
        );

        let constrained = acp::ElicitationSchema::new().property(
            "name",
            acp::StringPropertySchema::new().min_length(2),
            false,
        );
        assert!(
            normalize_form(
                "request-3".to_string(),
                TurnId::new("turn-3").expect("turn"),
                "Name?",
                constrained,
            )
            .is_err()
        );

        let plain_text = acp::ElicitationSchema::new().string("credential", false);
        assert!(
            normalize_form(
                "request-4".to_string(),
                TurnId::new("turn-4").expect("turn"),
                "Enter a credential",
                plain_text,
            )
            .is_err()
        );
    }

    #[test]
    fn required_choices_cannot_be_replaced_by_optional_custom_fields() {
        let mut schema = claude_form();
        schema.required = Some(vec!["question_0".to_string()]);
        let normalized = normalize_form(
            "request-1".to_string(),
            TurnId::new("turn-1").expect("turn"),
            "Which target?",
            schema,
        )
        .expect("normalize required choice");
        assert!(!normalized.request.questions[0].allows_other);
        assert!(
            answer_response(
                &normalized.fields,
                vec![QuestionAnswer {
                    question_id: "question_0".to_string(),
                    answers: vec!["user_note: Landing".to_string()],
                }],
            )
            .is_err()
        );
    }
}
