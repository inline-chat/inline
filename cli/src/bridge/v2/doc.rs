//! Builds a message's text and its `BlockContent` together.
//!
//! Every block is a UTF-16 range into `Message.message`, and that text is the
//! complete fallback for clients that predate the blocks, so the builder writes
//! readable plain text and records each block's range as it goes.

use inline_agent_bridge::harness::{FieldInput, QuestionForm};
use inline_protocol::proto;

/// One message: fallback text plus structured blocks.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Doc {
    pub text: String,
    pub blocks: Vec<proto::Block>,
}

impl Doc {
    pub(crate) fn block_content(&self) -> proto::BlockContent {
        proto::BlockContent {
            blocks: self.blocks.clone(),
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.text.trim().is_empty()
    }

    /// Adds a paragraph after the existing content.
    pub(crate) fn append_paragraph(&mut self, text: &str) {
        if text.trim().is_empty() {
            return;
        }
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        let offset = self.text.encode_utf16().count() as i64;
        self.text.push_str(text);
        self.blocks.push(proto::Block {
            kind: Some(proto::block::Kind::Paragraph(proto::BlockText {
                offset,
                length: text.encode_utf16().count() as i64,
                ..Default::default()
            })),
        });
    }
}

/// Status of a disclosure row or step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Status {
    None,
    Running,
    Waiting,
    Done,
    Failed,
    Cancelled,
}

impl Status {
    fn proto(self) -> i32 {
        (match self {
            Self::None => proto::BlockStatus::Unspecified,
            Self::Running => proto::BlockStatus::Running,
            Self::Waiting => proto::BlockStatus::Waiting,
            Self::Done => proto::BlockStatus::Done,
            Self::Failed => proto::BlockStatus::Failed,
            Self::Cancelled => proto::BlockStatus::Cancelled,
        }) as i32
    }
}

pub(crate) use proto::block_disclosure::ActivityKind;

/// Appends text and blocks. Nested builders share the same text.
#[derive(Debug, Default)]
pub(crate) struct DocBuilder {
    text: String,
    utf16: i64,
    blocks: Vec<proto::Block>,
}

impl DocBuilder {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.text.trim().is_empty()
    }

    pub(crate) fn finish(mut self) -> Doc {
        while self.text.ends_with('\n') {
            self.text.pop();
        }
        Doc {
            text: self.text,
            blocks: self.blocks,
        }
    }

    /// Appends text and returns its range (without the trailing newline).
    fn span(&mut self, text: &str) -> proto::BlockText {
        let offset = self.utf16;
        let length = text.encode_utf16().count() as i64;
        self.text.push_str(text);
        self.utf16 += length;
        self.push_raw("\n");
        proto::BlockText {
            offset,
            length,
            ..Default::default()
        }
    }

    fn push_raw(&mut self, text: &str) {
        self.text.push_str(text);
        self.utf16 += text.encode_utf16().count() as i64;
    }

    fn push_block(&mut self, kind: proto::block::Kind) {
        self.blocks.push(proto::Block { kind: Some(kind) });
    }

    pub(crate) fn paragraph(&mut self, text: &str) {
        if text.trim().is_empty() {
            return;
        }
        let span = self.span(text.trim_end());
        self.push_block(proto::block::Kind::Paragraph(span));
    }

    pub(crate) fn footer(&mut self, text: &str) {
        let span = self.span(text);
        self.push_block(proto::block::Kind::Footer(span));
    }

    pub(crate) fn code(&mut self, text: &str, language: Option<&str>) {
        if text.is_empty() {
            return;
        }
        let span = self.span(text.trim_end_matches('\n'));
        self.push_block(proto::block::Kind::Code(proto::BlockCode {
            text: Some(span),
            language: language.map(str::to_owned),
        }));
    }

    /// A label/value table, such as an approval's command, folder and reason.
    pub(crate) fn fields(&mut self, fields: &[(&str, String, bool)]) {
        let mut blocks = Vec::new();
        for (label, value, monospace) in fields {
            if value.trim().is_empty() {
                continue;
            }
            let label_span = {
                let offset = self.utf16;
                let text = format!("{label}: ");
                self.push_raw(&text);
                proto::BlockText {
                    offset,
                    length: label.encode_utf16().count() as i64,
                    ..Default::default()
                }
            };
            let value_span = self.span(value);
            blocks.push(proto::BlockField {
                label: Some(label_span),
                value: Some(value_span),
                monospace: *monospace,
            });
        }
        if !blocks.is_empty() {
            self.push_block(proto::block::Kind::Fields(proto::BlockFields {
                fields: blocks,
                ..Default::default()
            }));
        }
    }

    /// A question form. Field prompts and option labels are written as text
    /// too, so older apps can answer by replying. Options are `o<index>`.
    pub(crate) fn form(
        &mut self,
        form_id: &str,
        form: &QuestionForm,
        required_grant: proto::AgentGrantRequirement,
    ) {
        let title = form.title.as_deref().map(|title| self.span(title));
        let fields = form
            .fields
            .iter()
            .map(|field| {
                let label = self.span(&field.prompt);
                let kind = match &field.input {
                    FieldInput::Select {
                        options,
                        multiple,
                        allow_other,
                    } => proto::block_form_field::Kind::Select(proto::BlockFormSelect {
                        options: options
                            .iter()
                            .enumerate()
                            .map(|(index, option)| {
                                self.push_raw("• ");
                                let label = self.span(&option.label);
                                proto::BlockFormOption {
                                    option_id: format!("o{index}"),
                                    label: Some(label),
                                    description: None,
                                }
                            })
                            .collect(),
                        multiple: *multiple,
                        default_option_ids: Vec::new(),
                        allow_other: *allow_other,
                    }),
                    FieldInput::Text { multiline, default } => {
                        proto::block_form_field::Kind::Text(proto::BlockFormText {
                            kind: if *multiline {
                                proto::block_form_text::Kind::Multiline
                            } else {
                                proto::block_form_text::Kind::SingleLine
                            } as i32,
                            default_value: default.clone(),
                            ..Default::default()
                        })
                    }
                    FieldInput::Secret => {
                        proto::block_form_field::Kind::Text(proto::BlockFormText {
                            kind: proto::block_form_text::Kind::Secret as i32,
                            ..Default::default()
                        })
                    }
                    FieldInput::Toggle { default } => {
                        proto::block_form_field::Kind::Toggle(proto::BlockFormToggle {
                            default_value: default.unwrap_or(false),
                        })
                    }
                    FieldInput::Number { default, min, max } => {
                        proto::block_form_field::Kind::Number(proto::BlockFormNumber {
                            default_value: default.as_ref().and_then(|value| value.as_f64()),
                            min: min.as_ref().and_then(|value| value.as_f64()),
                            max: max.as_ref().and_then(|value| value.as_f64()),
                            ..Default::default()
                        })
                    }
                };
                proto::BlockFormField {
                    field_id: field.id.to_string(),
                    label: Some(label),
                    description: None,
                    required: field.required,
                    kind: Some(kind),
                }
            })
            .collect();
        self.push_block(proto::block::Kind::Form(proto::BlockForm {
            form_id: form_id.to_owned(),
            title,
            fields,
            submit_label: None,
            required_grant: required_grant as i32,
            closed: false,
            is_rtl: None,
        }));
    }

    pub(crate) fn steps(&mut self, steps: &[(String, Status)]) {
        let steps = steps
            .iter()
            .map(|(text, status)| {
                let marker = match status {
                    Status::Done => "[x] ",
                    Status::Running => "[>] ",
                    _ => "[ ] ",
                };
                self.push_raw(marker);
                proto::BlockStep {
                    text: Some(self.span(text)),
                    status: status.proto(),
                    detail: None,
                }
            })
            .collect();
        self.push_block(proto::block::Kind::Steps(proto::BlockSteps {
            steps,
            ..Default::default()
        }));
    }

    pub(crate) fn callout(&mut self, kind: CalloutKind, title: &str, body: &str) {
        let title = (!title.is_empty()).then(|| self.span(title));
        let mut children = DocBuilder {
            text: std::mem::take(&mut self.text),
            utf16: self.utf16,
            blocks: Vec::new(),
        };
        children.paragraph(body);
        self.text = children.text;
        self.utf16 = children.utf16;
        self.push_block(proto::block::Kind::Callout(proto::BlockCallout {
            kind: kind as i32,
            title,
            children: children.blocks,
            ..Default::default()
        }));
    }

    /// One file's diff.
    pub(crate) fn diff(&mut self, path: &str, change: DiffChange, diff: Option<&str>) {
        let (additions, deletions) = diff.map_or((None, None), |diff| {
            let added = diff
                .lines()
                .filter(|line| line.starts_with('+') && !line.starts_with("+++"))
                .count();
            let removed = diff
                .lines()
                .filter(|line| line.starts_with('-') && !line.starts_with("---"))
                .count();
            (Some(added as u32), Some(removed as u32))
        });
        let path = self.span(path);
        let text = diff
            .filter(|diff| !diff.is_empty())
            .map(|diff| self.span(diff.trim_end()));
        self.push_block(proto::block::Kind::Diff(proto::BlockDiff {
            path: Some(path),
            text,
            change: change as i32,
            additions,
            deletions,
            ..Default::default()
        }));
    }

    /// A collapsible row whose children are built by `build`.
    pub(crate) fn disclosure(
        &mut self,
        summary: &str,
        meta: Option<&str>,
        activity: ActivityKind,
        status: Status,
        build: impl FnOnce(&mut DocBuilder),
    ) {
        let summary_offset = self.utf16;
        let summary_len = summary.encode_utf16().count() as i64;
        self.push_raw(summary);
        let meta = meta.filter(|meta| !meta.is_empty()).map(|meta| {
            self.push_raw(" · ");
            let offset = self.utf16;
            self.push_raw(meta);
            proto::BlockText {
                offset,
                length: meta.encode_utf16().count() as i64,
                ..Default::default()
            }
        });
        self.push_raw("\n");
        let mut children = DocBuilder {
            text: std::mem::take(&mut self.text),
            utf16: self.utf16,
            blocks: Vec::new(),
        };
        build(&mut children);
        self.text = children.text;
        self.utf16 = children.utf16;
        self.push_block(proto::block::Kind::Disclosure(proto::BlockDisclosure {
            summary: Some(proto::BlockText {
                offset: summary_offset,
                length: summary_len,
                ..Default::default()
            }),
            kind: proto::block_disclosure::Kind::Progress as i32,
            children: children.blocks,
            activity_kind: activity as i32,
            status: status.proto(),
            meta,
            ..Default::default()
        }));
    }
}

pub(crate) use proto::block_callout::Kind as CalloutKind;
pub(crate) use proto::block_diff::Change as DiffChange;

#[cfg(test)]
mod tests {
    use super::*;

    fn slice(doc: &Doc, span: &proto::BlockText) -> String {
        let units: Vec<u16> = doc.text.encode_utf16().collect();
        String::from_utf16(&units[span.offset as usize..(span.offset + span.length) as usize])
            .expect("utf16")
    }

    #[test]
    fn ranges_point_at_their_text_even_after_non_ascii() {
        let mut builder = DocBuilder::new();
        builder.paragraph("Café ✅ ready");
        builder.disclosure(
            "Ran cargo test",
            Some("1.2s"),
            ActivityKind::Command,
            Status::Done,
            |children| children.code("ok 🚀", None),
        );
        let doc = builder.finish();
        let proto::block::Kind::Disclosure(disclosure) = doc.blocks[1].kind.clone().expect("kind")
        else {
            panic!("expected a disclosure");
        };
        assert_eq!(
            slice(&doc, &disclosure.summary.expect("summary")),
            "Ran cargo test"
        );
        assert_eq!(slice(&doc, &disclosure.meta.expect("meta")), "1.2s");
        let proto::block::Kind::Code(code) = disclosure.children[0].kind.clone().expect("child")
        else {
            panic!("expected code");
        };
        assert_eq!(slice(&doc, &code.text.expect("text")), "ok 🚀");
        assert_eq!(doc.text, "Café ✅ ready\nRan cargo test · 1.2s\nok 🚀");
    }

    #[test]
    fn fields_and_diffs_carry_readable_fallback() {
        let mut builder = DocBuilder::new();
        builder.fields(&[
            ("Command", "npm test".to_owned(), true),
            ("Reason", String::new(), false),
        ]);
        builder.diff(
            "src/a.rs",
            DiffChange::Modified,
            Some("@@ -1 +1 @@\n-a\n+b"),
        );
        let doc = builder.finish();
        assert_eq!(doc.text, "Command: npm test\nsrc/a.rs\n@@ -1 +1 @@\n-a\n+b");
        let proto::block::Kind::Diff(diff) = doc.blocks[1].kind.clone().expect("kind") else {
            panic!("expected diff");
        };
        assert_eq!((diff.additions, diff.deletions), (Some(1), Some(1)));
    }
}
