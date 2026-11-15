//! Code review findings: Codex review mode, and the `report_findings` tool
//! (Claude's ReportFindings for agents bridged into Inline).
//!
//! Codex writes its review for people as text (`render_review_output_text`):
//! the overall explanation, then "Full review comments:" (or "Review
//! comment:") and one "- [P1] Title — /abs/path:10-12" line per finding with
//! its body indented two spaces under it. [`parse_codex`] reads that back
//! into findings; text it can't read stays Markdown.

use std::path::Path;

use inline_protocol::proto;
use serde_json::Value;

use crate::bridge::v2::doc::{Doc, DocBuilder};
use crate::bridge::v2::limits;

use proto::block_review::Verdict;
use proto::block_review_finding::{Confidence, Outcome, Priority};

/// Findings one `report_findings` call reports.
pub(crate) const MAX_FINDINGS: usize = 50;
/// Findings one review block holds: the server's limit. A Codex review
/// with more shows the first ones and says how many it left out.
pub(crate) const MAX_BLOCK_FINDINGS: usize = 200;
/// A finding's body, in characters. [`doc`] shortens bodies further when
/// the whole review would pass Inline's message limit.
pub(crate) const MAX_BODY_CHARS: usize = 4_000;
/// Inline's limit on a finding's category.
const MAX_CATEGORY_CHARS: usize = 40;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Review {
    pub title: Option<String>,
    pub verdict: Option<Verdict>,
    pub summary: Option<String>,
    pub findings: Vec<Finding>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Finding {
    pub title: String,
    pub body: Option<String>,
    /// 0 to 3, P0 most urgent.
    pub priority: Option<u8>,
    pub path: Option<String>,
    pub start_line: Option<u32>,
    pub end_line: Option<u32>,
    pub category: Option<String>,
    pub confidence: Option<Confidence>,
    pub outcome: Option<Outcome>,
}

/// Codex's review text as a review block, or as Markdown when it is not in
/// the shape Codex writes.
pub(crate) fn codex(text: &str, folder: Option<&Path>) -> Doc {
    match parse_codex(text, folder) {
        Some(review) => doc(&review),
        None => Doc::markdown(text),
    }
}

/// Reads Codex's review text. Paths under `folder` become relative.
pub(crate) fn parse_codex(text: &str, folder: Option<&Path>) -> Option<Review> {
    let text = text.trim();
    if text.is_empty() || text == "Reviewer failed to output a response." {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    let header = lines.iter().position(|line| {
        matches!(
            line.trim(),
            "Full review comments:" | "Review comment:" | "Review comments:"
        )
    });
    let Some(header) = header else {
        // An explanation alone: nothing found.
        return Some(Review {
            title: Some("Code review".to_owned()),
            verdict: None,
            summary: Some(text.to_owned()),
            findings: Vec::new(),
        });
    };
    let summary = lines[..header].join("\n").trim().to_owned();
    let mut findings: Vec<Finding> = Vec::new();
    for line in &lines[header + 1..] {
        if line.trim().is_empty() {
            if let Some(body) = findings
                .last_mut()
                .and_then(|finding| finding.body.as_mut())
            {
                body.push('\n');
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("- ") {
            let rest = rest
                .strip_prefix("[x] ")
                .or_else(|| rest.strip_prefix("[ ] "))
                .unwrap_or(rest);
            findings.push(finding_line(rest, folder)?);
        } else if let Some(body_line) = line.strip_prefix("  ") {
            let finding = findings.last_mut()?;
            let body = finding.body.get_or_insert_with(String::new);
            if !body.is_empty() && !body.ends_with('\n') {
                body.push('\n');
            }
            body.push_str(body_line);
        } else {
            return None;
        }
    }
    if findings.is_empty() {
        return None;
    }
    let mut summary = summary;
    if findings.len() > MAX_BLOCK_FINDINGS {
        let more = findings.len() - MAX_BLOCK_FINDINGS;
        findings.truncate(MAX_BLOCK_FINDINGS);
        if !summary.is_empty() {
            summary.push_str("\n\n");
        }
        summary.push_str(&format!(
            "+{more} more {} not shown.",
            if more == 1 { "finding" } else { "findings" }
        ));
    }
    for finding in &mut findings {
        finding.body = finding
            .body
            .take()
            .map(|body| body.trim().to_owned())
            .filter(|body| !body.is_empty());
    }
    Some(Review {
        title: Some("Code review".to_owned()),
        verdict: Some(Verdict::NeedsAttention),
        summary: (!summary.is_empty()).then_some(summary),
        findings,
    })
}

/// "[P1] Title — /abs/path:10-12".
fn finding_line(line: &str, folder: Option<&Path>) -> Option<Finding> {
    let (title, location) = match line.rsplit_once(" — ") {
        Some((title, location)) => (title, Some(location)),
        None => (line, None),
    };
    let (priority, title) = priority_prefix(title.trim());
    if title.is_empty() {
        return None;
    }
    let mut finding = Finding {
        title: title.to_owned(),
        priority,
        ..Finding::default()
    };
    if let Some(location) = location.map(str::trim) {
        let (path, lines) = match location.rsplit_once(':') {
            Some((path, range)) if range.chars().all(|c| c.is_ascii_digit() || c == '-') => {
                (path, Some(range))
            }
            _ => (location, None),
        };
        let path = Path::new(path);
        finding.path = Some(
            folder
                .and_then(|folder| path.strip_prefix(folder).ok())
                .filter(|relative| !relative.as_os_str().is_empty())
                .unwrap_or(path)
                .display()
                .to_string(),
        );
        if let Some(range) = lines {
            let (start, end) = range.split_once('-').unwrap_or((range, range));
            finding.start_line = start.parse().ok().filter(|line| *line > 0);
            finding.end_line = end
                .parse()
                .ok()
                .filter(|end| finding.start_line.is_some_and(|start| *end >= start));
        }
    }
    Some(finding)
}

fn priority_prefix(title: &str) -> (Option<u8>, &str) {
    let bytes = title.as_bytes();
    if bytes.len() >= 4
        && bytes[0] == b'['
        && (bytes[1] == b'P' || bytes[1] == b'p')
        && bytes[2].is_ascii_digit()
        && bytes[3] == b']'
        && bytes[2] - b'0' <= 3
    {
        (Some(bytes[2] - b'0'), title[4..].trim())
    } else {
        (None, title)
    }
}

/// `report_findings` arguments as a review. Errors name what to fix.
pub(crate) fn reported(arguments: &Value) -> Result<Review, String> {
    let text = |value: &Value, key: &str| -> Option<String> {
        value
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    };
    let findings = arguments
        .get("findings")
        .and_then(Value::as_array)
        .ok_or("findings is required.")?;
    if findings.len() > MAX_FINDINGS {
        return Err(format!("Report at most {MAX_FINDINGS} findings."));
    }
    let findings = findings
        .iter()
        .enumerate()
        .map(|(index, finding)| {
            let title =
                text(finding, "title").ok_or(format!("findings[{index}].title is required."))?;
            let priority = match finding.get("priority").and_then(Value::as_str) {
                None => None,
                Some(value) => Some(
                    ["p0", "p1", "p2", "p3"]
                        .iter()
                        .position(|name| value.eq_ignore_ascii_case(name))
                        .ok_or(format!("findings[{index}].priority is p0 to p3."))?
                        as u8,
                ),
            };
            let line = |key: &str| {
                finding
                    .get(key)
                    .and_then(Value::as_u64)
                    .and_then(|line| u32::try_from(line).ok())
                    .filter(|line| *line > 0)
            };
            let start_line = line("start_line");
            let end_line =
                line("end_line").filter(|end| start_line.is_some_and(|start| *end >= start));
            let category = text(finding, "category");
            if let Some(category) = &category
                && !valid_category(category)
            {
                return Err(format!(
                    "findings[{index}].category is a lowercase slug such as \"correctness\"."
                ));
            }
            Ok(Finding {
                title,
                body: text(finding, "body"),
                priority,
                path: text(finding, "path"),
                start_line,
                end_line,
                category,
                confidence: match finding.get("confidence").and_then(Value::as_str) {
                    Some("confirmed") => Some(Confidence::Confirmed),
                    Some("plausible") => Some(Confidence::Plausible),
                    _ => None,
                },
                outcome: match finding.get("outcome").and_then(Value::as_str) {
                    Some("fixed") => Some(Outcome::Fixed),
                    Some("skipped") => Some(Outcome::Skipped),
                    Some("no_change_needed") => Some(Outcome::NoChangeNeeded),
                    _ => None,
                },
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    let review = Review {
        title: text(arguments, "title"),
        verdict: match arguments.get("verdict").and_then(Value::as_str) {
            Some("correct") => Some(Verdict::Correct),
            Some("incorrect") => Some(Verdict::Incorrect),
            Some("needs_attention") => Some(Verdict::NeedsAttention),
            _ => None,
        },
        summary: text(arguments, "summary"),
        findings,
    };
    if review.title.is_none() && review.summary.is_none() && review.findings.is_empty() {
        return Err("Report at least one finding, or a summary.".to_owned());
    }
    Ok(review)
}

fn valid_category(category: &str) -> bool {
    category.len() <= MAX_CATEGORY_CHARS
        && category.split(['-', '_']).all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
}

/// How much of a review's long text one message shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Shown {
    /// Each finding's body, in characters; none at 0.
    body: usize,
    /// The summary, title, finding titles and paths, in characters.
    text: Option<usize>,
}

impl Shown {
    const FULL: Self = Self {
        body: MAX_BODY_CHARS,
        text: None,
    };

    /// Less of it, bodies first: false once nothing is left to shorten.
    fn shorten(&mut self) -> bool {
        if self.body > 0 {
            self.body = if self.body > 250 { self.body / 2 } else { 0 };
            return true;
        }
        match self.text {
            None => self.text = Some(1_000),
            Some(text) if text > 60 => self.text = Some(text / 2),
            Some(_) => return false,
        }
        true
    }
}

/// The review block, with fallback text in Codex's own shape. A review
/// over Inline's message limit shows shorter finding bodies (then shorter
/// titles, paths and summary) until it fits, so a valid `report_findings`
/// call always sends.
pub(crate) fn doc(review: &Review) -> Doc {
    let mut shown = Shown::FULL;
    loop {
        let doc = build(review, shown);
        if limits::Size::of(&doc).fits() || !shown.shorten() {
            return doc;
        }
    }
}

fn build(review: &Review, shown: Shown) -> Doc {
    let text = |text: &str| match shown.text {
        Some(max) => super::head(text, max),
        None => text.to_owned(),
    };
    let mut builder = DocBuilder::new();
    let title = review
        .title
        .as_deref()
        .map(|title| builder.span(&text(title)));
    let summary = review
        .summary
        .as_deref()
        .map(|summary| builder.span(&text(summary)));
    let findings = review
        .findings
        .iter()
        .map(|finding| {
            if let Some(priority) = finding.priority {
                builder.push_raw(&format!("[P{priority}] "));
            }
            let title = builder.inline_span(&text(&finding.title));
            let path = finding.path.as_deref().map(|path| {
                builder.push_raw(" — ");
                builder.inline_span(&text(path))
            });
            match (path.is_some(), finding.start_line, finding.end_line) {
                (true, Some(start), Some(end)) if end != start => {
                    builder.push_raw(&format!(":{start}-{end}"));
                }
                (true, Some(start), _) => builder.push_raw(&format!(":{start}")),
                _ => {}
            }
            builder.newline();
            let body = finding
                .body
                .as_deref()
                .filter(|_| shown.body > 0)
                .map(|body| builder.span(&super::head(body, shown.body)));
            proto::BlockReviewFinding {
                title: Some(title),
                body,
                priority: match finding.priority {
                    Some(0) => Priority::P0,
                    Some(1) => Priority::P1,
                    Some(2) => Priority::P2,
                    Some(3) => Priority::P3,
                    _ => Priority::Unspecified,
                } as i32,
                path,
                start_line: finding.start_line,
                end_line: finding.end_line,
                category: finding.category.clone(),
                confidence: finding.confidence.unwrap_or(Confidence::Unspecified) as i32,
                outcome: finding.outcome.unwrap_or(Outcome::Unspecified) as i32,
                action_id: None,
            }
        })
        .collect();
    builder.push_block(proto::block::Kind::Review(proto::BlockReview {
        title,
        verdict: review.verdict.unwrap_or(Verdict::Unspecified) as i32,
        summary,
        findings,
        is_rtl: None,
    }));
    builder.finish()
}

#[cfg(test)]
pub(super) fn sample_codex(input: &Value) -> Vec<super::golden::Message> {
    let text = input["review"].as_str().expect("review text");
    let folder = input["folder"].as_str().map(Path::new);
    vec![super::golden::Message::new(
        "final",
        codex(text, folder),
        Vec::new(),
    )]
}

#[cfg(test)]
pub(super) fn sample_reported(input: &Value) -> Vec<super::golden::Message> {
    let doc = match reported(input) {
        Ok(review) => doc(&review),
        Err(error) => Doc::markdown(&format!("error: {error}")),
    };
    vec![super::golden::Message::new("message", doc, Vec::new())]
}

#[cfg(test)]
mod tests {
    use super::*;

    const CODEX: &str = "The change drops empty input, but two paths still break.\n\nFull review comments:\n\n- [P1] Guard the empty slice before indexing — /work/inline/src/parser.rs:42-48\n  `tokens[0]` panics when the input is blank.\n  Return early instead.\n\n- [P3] Typo in the error — /work/inline/src/error.rs:7-7\n  \"recieved\" should be \"received\".";

    #[test]
    fn codex_review_text_reads_back_into_findings() {
        let review = parse_codex(CODEX, Some(Path::new("/work/inline"))).expect("parsed");
        assert_eq!(
            review.summary.as_deref(),
            Some("The change drops empty input, but two paths still break.")
        );
        assert_eq!(review.findings.len(), 2);
        let first = &review.findings[0];
        assert_eq!(first.title, "Guard the empty slice before indexing");
        assert_eq!(first.priority, Some(1));
        assert_eq!(first.path.as_deref(), Some("src/parser.rs"));
        assert_eq!((first.start_line, first.end_line), (Some(42), Some(48)));
        assert_eq!(
            first.body.as_deref(),
            Some("`tokens[0]` panics when the input is blank.\nReturn early instead.")
        );
        assert_eq!(review.findings[1].priority, Some(3));
    }

    #[test]
    fn text_in_another_shape_stays_markdown() {
        assert!(parse_codex("Full review comments:\n\nnot a finding", None).is_none());
        assert!(parse_codex("Reviewer failed to output a response.", None).is_none());
        assert!(codex("Full review comments:\nstray", None).markdown);
        // An explanation alone is a review with nothing found.
        let clean = parse_codex("Looks correct.", None).expect("review");
        assert!(clean.findings.is_empty());
    }

    fn assert_ranges_inside(doc: &Doc) {
        let units = doc.text.encode_utf16().count() as i64;
        let Some(proto::block::Kind::Review(review)) = &doc.blocks[0].kind else {
            panic!("review");
        };
        let spans = review
            .findings
            .iter()
            .flat_map(|finding| {
                [
                    finding.title.as_ref(),
                    finding.body.as_ref(),
                    finding.path.as_ref(),
                ]
            })
            .chain([review.title.as_ref(), review.summary.as_ref()])
            .flatten();
        for span in spans {
            assert!(span.length > 0 && span.offset + span.length <= units);
        }
    }

    #[test]
    fn a_review_over_the_message_limit_shortens_its_bodies_until_it_fits() {
        // The most a schema-valid call can send: every finding at its
        // longest, in text that counts two UTF-16 units a character.
        let wide = |count: usize| "😀".repeat(count);
        let findings: Vec<Value> = (0..MAX_FINDINGS)
            .map(|index| {
                serde_json::json!({
                    "title": format!("{index} {}", wide(190)),
                    "body": wide(MAX_BODY_CHARS),
                    "path": wide(1024),
                    "priority": "p1",
                    "start_line": 3,
                })
            })
            .collect();
        let review = reported(&serde_json::json!({
            "title": wide(200),
            "summary": wide(4000),
            "findings": findings,
        }))
        .expect("valid");
        let doc = super::doc(&review);
        assert!(
            limits::Size::of(&doc).fits(),
            "{:?}",
            limits::Size::of(&doc)
        );
        assert_ranges_inside(&doc);
        let Some(proto::block::Kind::Review(block)) = &doc.blocks[0].kind else {
            panic!("review");
        };
        assert_eq!(block.findings.len(), MAX_FINDINGS);

        // Long bodies alone only shorten the bodies.
        let findings: Vec<Value> = (0..MAX_FINDINGS)
            .map(|index| serde_json::json!({"title": format!("Finding {index}"), "body": wide(MAX_BODY_CHARS)}))
            .collect();
        let review = reported(&serde_json::json!({"findings": findings})).expect("valid");
        let doc = super::doc(&review);
        assert!(limits::Size::of(&doc).fits());
        assert_ranges_inside(&doc);
        assert!(doc.text.contains("Finding 49\n"));
        let Some(proto::block::Kind::Review(block)) = &doc.blocks[0].kind else {
            panic!("review");
        };
        assert!(block.findings.iter().all(|finding| finding.body.is_some()));
    }

    #[test]
    fn a_review_within_the_limit_keeps_its_bodies_whole() {
        let review = parse_codex(CODEX, Some(Path::new("/work/inline"))).expect("parsed");
        let doc = super::doc(&review);
        assert!(doc.text.contains("Return early instead."));
    }

    #[test]
    fn codex_reviews_past_the_block_cap_keep_the_first_and_say_how_many_more() {
        let mut text = String::from("Several issues.\n\nFull review comments:\n");
        for index in 0..MAX_BLOCK_FINDINGS + 5 {
            text.push_str(&format!(
                "\n- [P2] Issue {index} — /work/src/a.rs:{}\n  Body {index}.\n",
                index + 1
            ));
        }
        let review = parse_codex(&text, Some(Path::new("/work"))).expect("parsed");
        assert_eq!(review.findings.len(), MAX_BLOCK_FINDINGS);
        assert_eq!(review.findings[0].title, "Issue 0");
        assert_eq!(
            review.summary.as_deref(),
            Some("Several issues.\n\n+5 more findings not shown.")
        );
        let doc = codex(&text, Some(Path::new("/work")));
        assert!(!doc.markdown);
        assert!(limits::Size::of(&doc).fits());
        assert_ranges_inside(&doc);
    }

    #[test]
    fn reported_findings_check_priority_and_category() {
        let error = reported(&serde_json::json!({
            "findings": [{"title": "x", "priority": "p9"}]
        }))
        .unwrap_err();
        assert!(error.contains("p0 to p3"), "{error}");
        let error = reported(&serde_json::json!({
            "findings": [{"title": "x", "category": "Has Spaces"}]
        }))
        .unwrap_err();
        assert!(error.contains("slug"), "{error}");
        let review = reported(&serde_json::json!({
            "findings": [{"title": "x", "start_line": 9, "end_line": 3}]
        }))
        .expect("review");
        assert_eq!(
            review.findings[0].end_line, None,
            "an end before the start is dropped"
        );
    }
}
