//! Builds a message's text and its `BlockContent` together.
//!
//! Every block is a UTF-16 range into `Message.message`, and that text is the
//! complete fallback for clients that predate the blocks, so the builder writes
//! readable plain text and records each block's range as it goes.

use inline_agent_bridge::harness::{FieldInput, QuestionForm};
use inline_agent_bridge::sanitize_visible_text;
use inline_protocol::proto;

/// One message: fallback text plus structured blocks.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct Doc {
    pub text: String,
    pub blocks: Vec<proto::Block>,
    /// `text` is Markdown for Inline to parse into blocks, as v1 sent answers;
    /// `blocks` is then empty.
    #[serde(default)]
    pub markdown: bool,
    /// Inline styles (code, bold, italic, links) over `text`, for the agent's
    /// prose inside blocks; empty for Markdown, which Inline styles itself.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub entities: Vec<proto::MessageEntity>,
}

impl Doc {
    /// The agent's own prose (answers, Friendly updates): Inline parses its
    /// Markdown, so headings, lists, code and links render.
    pub(crate) fn markdown(text: &str) -> Self {
        Self {
            text: sanitize_visible_text(text).trim().to_owned(),
            blocks: Vec::new(),
            markdown: true,
            entities: Vec::new(),
        }
    }

    pub(crate) fn block_content(&self) -> proto::BlockContent {
        proto::BlockContent {
            blocks: self.blocks.clone(),
        }
    }

    /// The styles to send with `text`, when it has any.
    pub(crate) fn message_entities(&self) -> Option<proto::MessageEntities> {
        (!self.markdown && !self.entities.is_empty()).then(|| proto::MessageEntities {
            entities: self.entities.clone(),
        })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.text.trim().is_empty()
    }

    /// Adds a paragraph after the existing content.
    pub(crate) fn append_paragraph(&mut self, text: &str) {
        let text = sanitize_visible_text(text);
        if text.trim().is_empty() {
            return;
        }
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        if self.markdown {
            self.text.push_str(&text);
            return;
        }
        let offset = self.text.encode_utf16().count() as i64;
        self.text.push_str(&text);
        self.blocks.push(proto::Block {
            kind: Some(proto::block::Kind::Paragraph(proto::BlockText {
                offset,
                length: text.encode_utf16().count() as i64,
                ..Default::default()
            })),
        });
    }
}

impl Doc {
    /// Adds a footer line after the existing content, such as a decided
    /// card's outcome.
    pub(crate) fn append_footer(&mut self, text: &str) {
        let text = sanitize_visible_text(text);
        let text = text.as_str();
        if text.trim().is_empty() || self.markdown {
            return;
        }
        if !self.text.is_empty() {
            self.text.push('\n');
        }
        let offset = self.text.encode_utf16().count() as i64;
        self.text.push_str(text);
        self.blocks.push(proto::Block {
            kind: Some(proto::block::Kind::Footer(proto::BlockText {
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
    /// Not started yet: a plan step still to do.
    Pending,
    Running,
    Waiting,
    Done,
    Failed,
    Cancelled,
}

impl Status {
    pub(crate) fn proto(self) -> i32 {
        (match self {
            Self::None => proto::BlockStatus::Unspecified,
            Self::Pending => proto::BlockStatus::Pending,
            Self::Running => proto::BlockStatus::Running,
            Self::Waiting => proto::BlockStatus::Waiting,
            Self::Done => proto::BlockStatus::Done,
            Self::Failed => proto::BlockStatus::Failed,
            Self::Cancelled => proto::BlockStatus::Cancelled,
        }) as i32
    }
}

pub(crate) use proto::block_disclosure::ActivityKind;

/// Line breaks a range never ends in.
const LINE_END: [char; 2] = ['\n', '\r'];

/// Styles one message carries; Inline refuses more than 1,024, and past this
/// the rest of the prose reads plain.
const MAX_ENTITIES: usize = 1_000;

/// Appends text and blocks. Nested builders share the same text.
#[derive(Debug, Default)]
pub(crate) struct DocBuilder {
    text: String,
    utf16: i64,
    blocks: Vec<proto::Block>,
    entities: Vec<proto::MessageEntity>,
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
            markdown: false,
            entities: self.entities,
        }
    }

    /// Appends text as its own line and returns its range (without the
    /// trailing newline). Line breaks at the end of `text` are left out:
    /// [`finish`](Self::finish) drops the message's trailing newlines, and a
    /// range must never reach past the text.
    pub(crate) fn span(&mut self, text: &str) -> proto::BlockText {
        let span = self.inline_span(text);
        self.newline();
        span
    }

    /// Appends the agent's Markdown as its own line, styled: inline code,
    /// bold, italic and links become entities over the plain text, the way
    /// Inline styles a Markdown message. Returns its range like [`span`](Self::span).
    pub(crate) fn markdown_span(&mut self, markdown: &str) -> proto::BlockText {
        let span = self.markdown_inline_span(markdown);
        self.newline();
        span
    }

    /// [`markdown_span`](Self::markdown_span) on the current line, without
    /// ending it: one cell of a table row.
    pub(crate) fn markdown_inline_span(&mut self, markdown: &str) -> proto::BlockText {
        // Sanitize before styling: the entities below are measured on this
        // text, so removing characters later would shift every one of them.
        let markdown = sanitize_visible_text(markdown);
        let styled = crate::bridge::v2::blocks::markdown::inline(&markdown);
        let text = styled.text.trim_end_matches(LINE_END);
        let end = text.encode_utf16().count() as i64;
        let offset = self.utf16;
        let room = MAX_ENTITIES.saturating_sub(self.entities.len());
        self.entities.extend(
            styled
                .entities
                .into_iter()
                .filter_map(|mut entity| {
                    entity.length = entity.length.min(end - entity.offset);
                    (entity.length > 0).then(|| {
                        entity.offset += offset;
                        entity
                    })
                })
                .take(room),
        );
        self.inline_span(text)
    }

    /// A paragraph of the agent's Markdown, styled as [`markdown_span`](Self::markdown_span).
    pub(crate) fn markdown_paragraph(&mut self, markdown: &str) {
        if markdown.trim().is_empty() {
            return;
        }
        let span = self.markdown_span(markdown.trim_end());
        self.push_block(proto::block::Kind::Paragraph(span));
    }

    /// Appends text no block covers, such as a "Command: " label.
    pub(crate) fn push_raw(&mut self, text: &str) {
        self.text.push_str(text);
        self.utf16 += text.encode_utf16().count() as i64;
    }

    /// Appends text on the current line and returns its range, without a
    /// newline: a span followed by more text on the same line.
    pub(crate) fn inline_span(&mut self, text: &str) -> proto::BlockText {
        // Sanitize before calculating offsets: removing bytes afterwards
        // corrupts all subsequent UTF-16 ranges. NUL also truncates GRDB's
        // native String decoding, making otherwise valid blocks disappear.
        let text = sanitize_visible_text(text);
        let text = text.trim_end_matches(LINE_END);
        let offset = self.utf16;
        self.push_raw(text);
        proto::BlockText {
            offset,
            length: text.encode_utf16().count() as i64,
            ..Default::default()
        }
    }

    /// Ends the current line.
    pub(crate) fn newline(&mut self) {
        self.push_raw("\n");
    }

    pub(crate) fn push_block(&mut self, kind: proto::block::Kind) {
        self.blocks.push(proto::Block { kind: Some(kind) });
    }

    /// Child blocks written by `build` into the same text, for a block that
    /// holds others (a plan's body, an approval's diffs).
    pub(crate) fn nested(&mut self, build: impl FnOnce(&mut DocBuilder)) -> Vec<proto::Block> {
        let mut children = DocBuilder {
            text: std::mem::take(&mut self.text),
            utf16: self.utf16,
            blocks: Vec::new(),
            entities: std::mem::take(&mut self.entities),
        };
        build(&mut children);
        self.text = children.text;
        self.utf16 = children.utf16;
        self.entities = children.entities;
        children.blocks
    }

    pub(crate) fn heading(&mut self, text: &str, level: u32) {
        if text.trim().is_empty() {
            return;
        }
        let span = self.span(text.trim());
        self.push_block(proto::block::Kind::Heading(proto::BlockHeading {
            text: Some(span),
            level,
        }));
    }

    pub(crate) fn paragraph(&mut self, text: &str) {
        let text = sanitize_visible_text(text);
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
        let text = sanitize_visible_text(text);
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
            let label_span = self.inline_span(label);
            self.push_raw(": ");
            let value_span = self.span(value.trim_end());
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
            .enumerate()
            .map(|(index, field)| {
                let header = field
                    .header
                    .as_deref()
                    .filter(|header| !header.trim().is_empty())
                    .map(|header| self.span(header.trim()));
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
                                let description = option
                                    .description
                                    .as_deref()
                                    .filter(|text| !text.trim().is_empty())
                                    .map(|text| self.span(text.trim()));
                                let preview = option
                                    .preview
                                    .as_deref()
                                    .filter(|preview| !preview.trim().is_empty())
                                    .map(|preview| self.span(preview.trim_end()));
                                proto::BlockFormOption {
                                    option_id: format!("o{index}"),
                                    label: Some(label),
                                    description,
                                    preview,
                                    recommended: is_recommended(&option.label),
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
                    // Harness field IDs can be free text (Claude uses the
                    // question); Inline's must be short identifiers.
                    field_id: form_field_id(index),
                    label: Some(label),
                    description: None,
                    required: field.required,
                    kind: Some(kind),
                    header,
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
                    Status::Running | Status::Waiting => "[>] ",
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
        let children = self.nested(|children| children.paragraph(body));
        self.push_block(proto::block::Kind::Callout(proto::BlockCallout {
            kind: kind as i32,
            title,
            children,
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
        let summary = self.inline_span(summary);
        let meta = meta
            .map(|meta| meta.trim_end_matches(LINE_END))
            .filter(|meta| !meta.is_empty())
            .map(|meta| {
                self.push_raw(" · ");
                self.inline_span(meta)
            });
        self.push_raw("\n");
        let children = self.nested(build);
        self.push_block(proto::block::Kind::Disclosure(proto::BlockDisclosure {
            summary: Some(summary),
            children,
            activity_kind: activity as i32,
            status: status.proto(),
            meta,
            ..Default::default()
        }));
    }

    /// A progress message's outer row, as v1 drew it: "Working" (animated
    /// and open) while `working`, then its final summary, closed. While
    /// working, `elapsed` lets clients count up from its start; its text is
    /// the time as of this edit, for clients that can't.
    pub(crate) fn progress(
        &mut self,
        summary: &str,
        working: bool,
        elapsed: Option<Elapsed<'_>>,
        build: impl FnOnce(&mut DocBuilder),
    ) {
        let summary = self.inline_span(summary);
        let elapsed = elapsed.filter(|_| working);
        let meta = elapsed.as_ref().map(|elapsed| {
            self.push_raw(" · ");
            self.inline_span(elapsed.text)
        });
        self.push_raw("\n");
        let children = self.nested(build);
        let kind = if working {
            proto::block_disclosure::Kind::Progress
        } else {
            proto::block_disclosure::Kind::Default
        };
        self.push_block(proto::block::Kind::Disclosure(proto::BlockDisclosure {
            summary: Some(summary),
            kind: kind as i32,
            // Open while working and after: the turn's work stays visible
            // (Oct 31 rule 1); a person's own collapse is kept by the apps.
            initially_open: Some(true),
            children,
            meta,
            started_at: elapsed.map(|elapsed| elapsed.started_at),
            ..Default::default()
        }));
    }
}

/// How long a progress message's work has run: its start, Unix seconds, and
/// the time as of this edit, such as "1m 40s".
pub(crate) struct Elapsed<'a> {
    pub started_at: i64,
    pub text: &'a str,
}

pub(crate) use proto::block_callout::Kind as CalloutKind;
pub(crate) use proto::block_diff::Change as DiffChange;

/// Claude marks the option it recommends with "(Recommended)" on its label.
pub(crate) fn is_recommended(label: &str) -> bool {
    label
        .trim_end()
        .to_ascii_lowercase()
        .ends_with("(recommended)")
}

/// The Inline form field ID of a harness question, by position.
pub(crate) fn form_field_id(index: usize) -> String {
    format!("f{index}")
}

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

    fn assert_inside(doc: &Doc, span: &proto::BlockText) {
        let units = doc.text.encode_utf16().count() as i64;
        assert!(
            span.length > 0 && span.offset + span.length <= units,
            "range {}+{} outside {units} units of {:?}",
            span.offset,
            span.length,
            doc.text
        );
    }

    #[test]
    fn a_value_ending_in_a_newline_stays_inside_the_text() {
        let mut builder = DocBuilder::new();
        builder.fields(&[("Reason", "it needs the network\n".to_owned(), false)]);
        let doc = builder.finish();
        assert_eq!(doc.text, "Reason: it needs the network");
        let proto::block::Kind::Fields(fields) = doc.blocks[0].kind.clone().expect("kind") else {
            panic!("expected fields");
        };
        let value = fields.fields[0].value.clone().expect("value");
        assert_inside(&doc, &value);
        assert_eq!(slice(&doc, &value), "it needs the network");

        // Any span, inline span or row summary last in the message.
        let mut builder = DocBuilder::new();
        let span = builder.span("ends with breaks\r\n\n");
        let doc = builder.finish();
        assert_inside(&doc, &span);
        assert_eq!(slice(&doc, &span), "ends with breaks");

        let mut builder = DocBuilder::new();
        let span = builder.inline_span("inline\n");
        let doc = builder.finish();
        assert_inside(&doc, &span);

        let mut builder = DocBuilder::new();
        builder.disclosure(
            "Ran it\n",
            Some("1s\n"),
            ActivityKind::Command,
            Status::Done,
            |_| {},
        );
        let doc = builder.finish();
        let proto::block::Kind::Disclosure(row) = doc.blocks[0].kind.clone().expect("kind") else {
            panic!("expected a disclosure");
        };
        assert_inside(&doc, &row.summary.expect("summary"));
        assert_inside(&doc, &row.meta.expect("meta"));
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

    #[test]
    fn binary_tool_output_is_sanitized_before_block_ranges_are_written() {
        let mut builder = DocBuilder::new();
        builder.progress("Work\0ing", true, None, |progress| {
            progress.disclosure(
                "Ran\0 command 🚀",
                Some("1\u{1b}[31ms\u{1b}[0m"),
                ActivityKind::Command,
                Status::Done,
                |row| row.code("before\0\u{12}\u{1b}[31mafter 🚀\u{1b}[0m\r\n\tend", None),
            );
        });
        let doc = builder.finish();
        assert_eq!(
            doc.text,
            "Working\nRan command 🚀 · 1s\nbeforeafter 🚀\n\tend"
        );
        let Some(proto::block::Kind::Disclosure(progress)) = &doc.blocks[0].kind else {
            panic!()
        };
        assert_eq!(slice(&doc, progress.summary.as_ref().unwrap()), "Working");
        let Some(proto::block::Kind::Disclosure(row)) = &progress.children[0].kind else {
            panic!()
        };
        assert_eq!(slice(&doc, row.summary.as_ref().unwrap()), "Ran command 🚀");
        assert_eq!(slice(&doc, row.meta.as_ref().unwrap()), "1s");
        let Some(proto::block::Kind::Code(code)) = &row.children[0].kind else {
            panic!()
        };
        assert_eq!(
            slice(&doc, code.text.as_ref().unwrap()),
            "beforeafter 🚀\n\tend"
        );
    }

    #[test]
    fn control_only_text_adds_no_block() {
        let mut builder = DocBuilder::new();
        builder.paragraph("\0\u{12}");
        builder.code("\0\u{1b}[31m", None);
        assert!(builder.blocks.is_empty());
        assert!(builder.finish().text.is_empty());
    }

    #[test]
    fn field_ranges_end_before_trailing_newlines_and_labels_are_sanitized() {
        let mut builder = DocBuilder::new();
        builder.fields(&[("Rea\0son", "done 🚀\n\n".to_owned(), false)]);
        let doc = builder.finish();
        let Some(proto::block::Kind::Fields(fields)) = &doc.blocks[0].kind else {
            panic!()
        };
        assert_eq!(
            slice(&doc, fields.fields[0].label.as_ref().unwrap()),
            "Reason"
        );
        assert_eq!(
            slice(&doc, fields.fields[0].value.as_ref().unwrap()),
            "done 🚀"
        );
        assert!(!Doc::markdown("before\0after").text.contains('\0'));
    }

    #[test]
    fn styled_prose_ranges_survive_control_characters() {
        let mut builder = DocBuilder::new();
        builder.markdown_paragraph("ru\0n `cargo\u{1b}[31m test` 🚀 **now**");
        let doc = builder.finish();
        assert!(!doc.text.contains('\0'));
        let styled: Vec<String> = doc
            .entities
            .iter()
            .map(|entity| {
                slice(
                    &doc,
                    &proto::BlockText {
                        offset: entity.offset,
                        length: entity.length,
                        ..Default::default()
                    },
                )
            })
            .collect();
        assert_eq!(styled, ["cargo test", "now"]);
    }
}
