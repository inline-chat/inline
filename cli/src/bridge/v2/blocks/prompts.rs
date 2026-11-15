//! Inline tool `suggest_prompts`: suggested follow-up prompts.
//!
//! Chips under the message; a tap puts the prompt in the viewer's composer
//! to edit and send (client-side, like `MessageActionCompose`). The composer
//! text, when it differs from the label, is not part of the fallback text.

use inline_protocol::proto;

use crate::bridge::v2::doc::{Doc, DocBuilder};

/// Most prompts one message suggests.
pub(crate) const MAX_PROMPTS: usize = 4;
/// A chip's label, in characters.
pub(crate) const MAX_LABEL_CHARS: usize = 80;
/// Composer text, in UTF-16 units (Inline's limit, as the server counts).
pub(crate) const MAX_TEXT_CHARS: usize = 4_000;

/// One suggestion: its label and, when it differs, the composer text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Prompt {
    pub label: String,
    pub text: Option<String>,
}

pub(crate) fn card(prompts: &[Prompt]) -> Doc {
    let mut builder = DocBuilder::new();
    builder.push_raw("Suggested prompts:\n");
    let prompts = prompts
        .iter()
        .take(MAX_PROMPTS)
        .map(|prompt| {
            builder.push_raw("• ");
            let label = builder.span(prompt.label.trim());
            proto::BlockPromptSuggestion {
                label: Some(label),
                text: prompt
                    .text
                    .as_deref()
                    .map(str::trim)
                    .filter(|text| !text.is_empty() && *text != prompt.label.trim())
                    // The tool's schema counts characters; Inline counts
                    // UTF-16 units, so text outside the BMP is cut here.
                    .map(|text| super::utf16_prefix(text, MAX_TEXT_CHARS).to_owned()),
            }
        })
        .collect();
    builder.push_block(proto::block::Kind::PromptSuggestions(
        proto::BlockPromptSuggestions {
            prompts,
            is_rtl: None,
        },
    ));
    builder.finish()
}

/// `suggest_prompts` arguments.
pub(crate) fn from_arguments(arguments: &serde_json::Value) -> Result<Vec<Prompt>, String> {
    let prompts: Vec<Prompt> = arguments
        .get("prompts")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|prompt| {
            let label = prompt.get("label")?.as_str()?.trim();
            (!label.is_empty()).then(|| Prompt {
                label: label.to_owned(),
                text: prompt
                    .get("text")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
            })
        })
        .collect();
    if prompts.is_empty() || prompts.len() > MAX_PROMPTS {
        return Err(format!("Suggest 1 to {MAX_PROMPTS} prompts."));
    }
    Ok(prompts)
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    let doc = match from_arguments(input) {
        Ok(prompts) => card(&prompts),
        Err(error) => Doc::markdown(&format!("error: {error}")),
    };
    vec![super::golden::Message::new("message", doc, Vec::new())]
}

#[cfg(test)]
mod tests {
    use inline_protocol::proto;

    use super::*;

    #[test]
    fn composer_text_fits_inlines_utf16_limit() {
        let prompts = from_arguments(&serde_json::json!({
            "prompts": [{"label": "Celebrate", "text": "🎉".repeat(MAX_TEXT_CHARS)}]
        }))
        .expect("valid");
        let doc = card(&prompts);
        let Some(proto::block::Kind::PromptSuggestions(block)) = &doc.blocks[0].kind else {
            panic!("prompts");
        };
        let text = block.prompts[0].text.as_deref().expect("text");
        assert_eq!(text.encode_utf16().count(), MAX_TEXT_CHARS);
        assert!(text.chars().all(|c| c == '🎉'));
    }
}
