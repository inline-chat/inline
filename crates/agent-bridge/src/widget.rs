//! Message widgets in an agent's Markdown answer.
//!
//! A bot's Markdown may hold one Agent Flavored Markdown HTML preview,
//! `<iframe title="…" id="…" height="…">HTML</iframe>`, which Inline turns
//! into a sandboxed widget. These helpers find previews as the server does
//! (`server/src/modules/message/messageWidgets.ts`): the opening tag starts a
//! line outside code fences, and the first `</iframe>` after it ends the
//! payload and must end its line. Inline refuses the whole message when a
//! preview is unclosed or a second one follows, so callers hold back an
//! unfinished preview while streaming, keep one preview per message when
//! splitting, and show only titles in plain-text fallbacks.

use std::borrow::Cow;

/// The server's title for a preview without one.
pub const DEFAULT_TITLE: &str = "HTML preview";
/// The server's longest title.
const MAX_TITLE_CHARS: usize = 256;
const OPENER: &[u8] = b"<iframe";
const CLOSER: &[u8] = b"</iframe";

/// One preview in a Markdown text, as byte offsets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WidgetSpan {
    /// Start of the line holding the opening tag.
    pub start: usize,
    /// Just past the closing tag's line and its line break, or the text's end
    /// when the preview is unclosed.
    pub end: usize,
    pub title: String,
    /// Whether a `</iframe>` ends the payload.
    pub closed: bool,
}

/// The previews in `text`, in order. An unclosed preview runs to the end and
/// is last.
pub fn spans(text: &str) -> Vec<WidgetSpan> {
    scan(text).0
}

/// `text` without a preview that is still being written: cut at the start of
/// an unclosed preview, or of a last line that may yet become an opening tag.
pub fn hold_back(text: &str) -> &str {
    let (spans, partial) = scan(text);
    match spans.iter().find(|span| !span.closed) {
        Some(open) => &text[..open.start],
        None => partial.map_or(text, |start| &text[..start]),
    }
}

/// Each preview replaced by its title line, never its HTML. An unclosed
/// preview takes the rest of the text with it, as Inline would.
pub fn replace_with_titles(text: &str) -> Cow<'_, str> {
    let spans = spans(text);
    if spans.is_empty() {
        return Cow::Borrowed(text);
    }
    let mut output = String::with_capacity(text.len());
    let mut last = 0;
    for span in spans {
        output.push_str(&text[last..span.start]);
        output.push_str(&placeholder(&span.title));
        if text[..span.end].ends_with('\n') {
            output.push('\n');
        }
        last = span.end;
    }
    output.push_str(&text[last..]);
    Cow::Owned(output)
}

/// Streaming text for a progress view: finished previews as their titles and
/// an unfinished one held back.
pub fn preview(text: &str) -> Cow<'_, str> {
    match replace_with_titles(hold_back(text)) {
        Cow::Borrowed(kept) if kept.len() == text.len() => Cow::Borrowed(text),
        other => Cow::Owned(other.into_owned()),
    }
}

/// How a preview reads where its HTML can't be shown.
pub fn placeholder(title: &str) -> String {
    format!("[Widget: {title}]")
}

/// A Markdown code fence, matched as the server's fence parser does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fence {
    character: char,
    length: usize,
}

impl Fence {
    /// The fence `line` opens: up to three spaces, then three or more
    /// backticks or tildes (a backtick fence's info has no backtick).
    pub fn opening(line: &str) -> Option<Self> {
        let rest = line.trim_start_matches(' ');
        if line.len() - rest.len() > 3 {
            return None;
        }
        let character = rest.chars().next().filter(|c| matches!(c, '`' | '~'))?;
        let length = rest.chars().take_while(|c| *c == character).count();
        if length < 3 || character == '`' && rest[length..].contains('`') {
            return None;
        }
        Some(Self { character, length })
    }

    /// Whether `line` closes this fence.
    pub fn closed_by(self, line: &str) -> bool {
        let rest = line.trim_start_matches(' ');
        if line.len() - rest.len() > 3 {
            return false;
        }
        let run = rest.chars().take_while(|c| *c == self.character).count();
        run >= self.length && rest[run..].chars().all(|c| matches!(c, ' ' | '\t'))
    }

    /// A line that closes this fence.
    pub fn closer(self) -> String {
        self.character.to_string().repeat(self.length)
    }
}

/// Complete previews, plus the start of a last, unterminated line that may
/// still become an opening tag.
fn scan(text: &str) -> (Vec<WidgetSpan>, Option<usize>) {
    let mut found = Vec::new();
    let mut fence: Option<Fence> = None;
    let mut cursor = 0;
    while cursor < text.len() {
        let (line, next) = read_line(text, cursor);
        if let Some(open) = fence {
            if open.closed_by(line) {
                fence = None;
            }
            cursor = next;
            continue;
        }
        if let Some(open) = Fence::opening(line) {
            fence = Some(open);
            cursor = next;
            continue;
        }
        let Some((attributes, tag_length)) = opening_tag(line) else {
            if next == text.len() && !text.ends_with('\n') && partial_opening_tag(line) {
                return (found, Some(cursor));
            }
            cursor = next;
            continue;
        };
        let title = title(attributes);
        match closing_tag(text, cursor + tag_length) {
            Some(close_end) => {
                let end = text[close_end..]
                    .find('\n')
                    .map_or(text.len(), |offset| close_end + offset + 1);
                found.push(WidgetSpan {
                    start: cursor,
                    end,
                    title,
                    closed: true,
                });
                cursor = end;
            }
            None => {
                found.push(WidgetSpan {
                    start: cursor,
                    end: text.len(),
                    title,
                    closed: false,
                });
                break;
            }
        }
    }
    (found, None)
}

/// The line at `start` without its line break, and where the next begins.
fn read_line(text: &str, start: usize) -> (&str, usize) {
    let (end, next) = text[start..]
        .find('\n')
        .map_or((text.len(), text.len()), |offset| {
            (start + offset, start + offset + 1)
        });
    let line = &text[start..end];
    (line.strip_suffix('\r').unwrap_or(line), next)
}

/// `<iframe` + whitespace or `>`, attributes (quoted values may hold `>`),
/// then `>`, all on the line: the attributes and the tag's length.
fn opening_tag(line: &str) -> Option<(&str, usize)> {
    let bytes = line.as_bytes();
    if bytes.len() <= OPENER.len() || !bytes[..OPENER.len()].eq_ignore_ascii_case(OPENER) {
        return None;
    }
    let after = &line[OPENER.len()..];
    let first = after.chars().next()?;
    if !(first.is_whitespace() || first == '>') {
        return None;
    }
    let mut quote = None;
    for (index, character) in after.char_indices() {
        match (quote, character) {
            (Some(open), _) if character == open => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(character),
            (None, '<') => return None,
            (None, '>') => return Some((&after[..index], OPENER.len() + index + 1)),
            (None, _) => {}
        }
    }
    None
}

/// A line that is, so far, the start of an opening tag.
fn partial_opening_tag(line: &str) -> bool {
    let bytes = line.as_bytes();
    if bytes.len() <= OPENER.len() {
        return !bytes.is_empty() && OPENER[..bytes.len()].eq_ignore_ascii_case(bytes);
    }
    bytes[..OPENER.len()].eq_ignore_ascii_case(OPENER)
        && line[OPENER.len()..]
            .chars()
            .next()
            .is_some_and(char::is_whitespace)
}

/// The end of the first `</iframe\s*>` at or after `from`.
fn closing_tag(text: &str, from: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut cursor = from;
    while let Some(offset) = bytes[cursor..]
        .windows(CLOSER.len())
        .position(|window| window.eq_ignore_ascii_case(CLOSER))
    {
        let tag = cursor + offset;
        let rest = &text[tag + CLOSER.len()..];
        let after_space = rest.trim_start();
        if after_space.starts_with('>') {
            return Some(tag + CLOSER.len() + (rest.len() - after_space.len()) + 1);
        }
        cursor = tag + 1;
    }
    None
}

/// The `title` attribute as the server reads it: entities decoded,
/// whitespace collapsed, at most 256 characters, or the default.
fn title(attributes: &str) -> String {
    let title = attribute(attributes, "title").unwrap_or_default();
    let title: String = title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_TITLE_CHARS)
        .collect();
    if title.is_empty() {
        DEFAULT_TITLE.to_owned()
    } else {
        title
    }
}

/// The first value of attribute `wanted` (lowercase), decoded.
fn attribute(source: &str, wanted: &str) -> Option<String> {
    let name_start = |c: char| c.is_ascii_alphabetic() || matches!(c, '_' | ':');
    let name_char = |c: char| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '.' | '-');
    let mut rest = source;
    while let Some(start) = rest.find(name_start) {
        rest = &rest[start..];
        let name_end = rest.find(|c: char| !name_char(c)).unwrap_or(rest.len());
        let name = rest[..name_end].to_ascii_lowercase();
        rest = &rest[name_end..];
        let mut value = None;
        let equals = rest.len() - rest.trim_start().len();
        if let Some(after_equals) = rest[equals..].strip_prefix('=') {
            let start = equals + 1 + after_equals.len() - after_equals.trim_start().len();
            let candidate = &rest[start..];
            let quoted = |quote: char| {
                candidate
                    .strip_prefix(quote)
                    .and_then(|inner| inner.find(quote).map(|end| (&inner[..end], end + 2)))
            };
            let parsed = quoted('"').or_else(|| quoted('\'')).or_else(|| {
                let end = candidate
                    .find(|c: char| c.is_whitespace() || "\"'=<>`".contains(c))
                    .unwrap_or(candidate.len());
                (end > 0).then(|| (&candidate[..end], end))
            });
            if let Some((raw, consumed)) = parsed {
                value = Some(raw);
                rest = &rest[start + consumed..];
            }
        }
        if name == wanted {
            return Some(decode_entities(value.unwrap_or_default()));
        }
    }
    None
}

fn decode_entities(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(start) = rest.find('&') {
        output.push_str(&rest[..start]);
        rest = &rest[start..];
        let decoded = [
            ("&quot;", '"'),
            ("&amp;", '&'),
            ("&lt;", '<'),
            ("&gt;", '>'),
            ("&#39;", '\''),
            ("&apos;", '\''),
        ]
        .into_iter()
        .find(|(entity, _)| rest.starts_with(entity));
        match decoded {
            Some((entity, character)) => {
                output.push(character);
                rest = &rest[entity.len()..];
            }
            None => {
                output.push('&');
                rest = &rest[1..];
            }
        }
    }
    output.push_str(rest);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    const ANSWER: &str = "Revenue grew 18% this quarter.\n\n\
<iframe title=\"Q3 revenue\" id=\"revenue\" height=\"420\">\n\
<div class=\"card\">chart</div>\n\
</iframe>\n\
\n\
The dip in August was the pricing change.";

    #[test]
    fn finds_a_preview_with_its_title() {
        let spans = spans(ANSWER);
        assert_eq!(spans.len(), 1);
        let span = &spans[0];
        assert!(span.closed);
        assert_eq!(span.title, "Q3 revenue");
        assert!(ANSWER[span.start..].starts_with("<iframe"));
        assert!(ANSWER[..span.end].ends_with("</iframe>\n"));
    }

    #[test]
    fn previews_in_code_fences_stay_code() {
        let text =
            "```html\n<iframe title=\"a\">\nx\n</iframe>\n```\n\n~~~~\n<iframe>\n~~~\n~~~~\n";
        assert!(spans(text).is_empty());
        assert_eq!(hold_back(text), text);
    }

    #[test]
    fn the_opening_tag_must_start_a_line() {
        assert!(spans("Use  <iframe title=\"a\">x</iframe> here").is_empty());
        assert!(spans(" <iframe>x</iframe>").is_empty());
        assert!(spans("<iframes>x</iframe>").is_empty());
        assert_eq!(spans("<IFRAME TITLE='Up'>x</IFRAME >").len(), 1);
    }

    #[test]
    fn titles_decode_collapse_and_default() {
        let title_of = |text: &str| spans(text)[0].title.clone();
        assert_eq!(
            title_of("<iframe id=\"a\" title=\" Q&amp;A \t  x \">x</iframe>"),
            "Q&A x"
        );
        assert_eq!(
            title_of("<iframe data-title=\"no\" title='It\"s'>x</iframe>"),
            "It\"s"
        );
        assert_eq!(title_of("<iframe title=Bare>x</iframe>"), "Bare");
        assert_eq!(title_of("<iframe height=\"300\">x</iframe>"), DEFAULT_TITLE);
        assert_eq!(title_of("<iframe title=\"a > b\">x</iframe>"), "a > b");
    }

    #[test]
    fn several_previews_and_an_unclosed_one() {
        let text = "<iframe title=\"One\">\na\n</iframe>\ntext\n<iframe title=\"Two\">\nb\n";
        let spans = spans(text);
        assert_eq!(spans.len(), 2);
        assert!(spans[0].closed && !spans[1].closed);
        assert_eq!(spans[1].end, text.len());
        assert_eq!(&text[spans[0].end..spans[1].start], "text\n");
    }

    #[test]
    fn streaming_holds_back_an_unfinished_preview() {
        let cut = ANSWER.find("<div").expect("body");
        assert_eq!(
            hold_back(&ANSWER[..cut]),
            "Revenue grew 18% this quarter.\n\n"
        );
        for partial in ["<", "<ifr", "<IFRAME", "<iframe ", "<iframe title=\"Q3"] {
            let text = format!("Intro\n\n{partial}");
            assert_eq!(hold_back(&text), "Intro\n\n", "{partial}");
        }
        assert_eq!(hold_back("a < b"), "a < b");
        assert_eq!(hold_back("Intro\n<b>"), "Intro\n<b>");
        assert_eq!(hold_back(ANSWER), ANSWER);
    }

    #[test]
    fn fallback_shows_titles_never_html() {
        let replaced = replace_with_titles(ANSWER);
        assert_eq!(
            replaced,
            "Revenue grew 18% this quarter.\n\n[Widget: Q3 revenue]\n\nThe dip in August was the pricing change."
        );
        let unclosed = replace_with_titles("Hi\n<iframe title=\"T\">\n<div>");
        assert_eq!(unclosed, "Hi\n[Widget: T]");
        assert!(matches!(replace_with_titles("plain"), Cow::Borrowed(_)));
    }

    #[test]
    fn progress_preview_combines_both() {
        let text = format!("{ANSWER}\n\n<iframe title=\"Next\">\n<p>");
        assert_eq!(
            preview(&text),
            "Revenue grew 18% this quarter.\n\n[Widget: Q3 revenue]\n\nThe dip in August was the pricing change.\n\n"
        );
        assert!(matches!(preview("plain"), Cow::Borrowed(_)));
    }

    #[test]
    fn fences_match_the_server() {
        assert!(Fence::opening("```rust").is_some());
        assert!(Fence::opening("   ~~~").is_some());
        assert!(Fence::opening("    ```").is_none());
        assert!(Fence::opening("``").is_none());
        assert!(Fence::opening("```a`b").is_none());
        let fence = Fence::opening("````").expect("fence");
        assert!(!fence.closed_by("```"));
        assert!(fence.closed_by("`````  "));
        assert!(!fence.closed_by("~~~~"));
        assert_eq!(fence.closer(), "````");
    }
}
