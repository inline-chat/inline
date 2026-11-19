//! Agent Markdown (a plan's body, prose between tool calls) as blocks inside
//! another block.
//!
//! A message whose text is Markdown is parsed by Inline itself, but a block's
//! children are built here, so this is the 90/10 of it, line by line:
//! headings, fenced code, bullet, numbered and task lists, and paragraphs.
//! Inline code, bold, italic, strikethrough and links become message entities
//! over the plain text, as Inline styles a Markdown message.

use inline_protocol::proto;

use crate::bridge::v2::doc::DocBuilder;

/// Writes `markdown` as blocks.
pub(crate) fn write(builder: &mut DocBuilder, markdown: &str) {
    let lines: Vec<&str> = markdown.lines().collect();
    let mut paragraph: Vec<String> = Vec::new();
    let mut index = 0;
    let flush = |builder: &mut DocBuilder, paragraph: &mut Vec<String>| {
        if !paragraph.is_empty() {
            builder.markdown_paragraph(&paragraph.join("\n"));
            paragraph.clear();
        }
    };
    while index < lines.len() {
        let line = lines[index];
        let trimmed = line.trim();
        if let Some(fence) = fence(trimmed) {
            flush(builder, &mut paragraph);
            let language = trimmed[fence.len()..].trim();
            let mut code = Vec::new();
            index += 1;
            while index < lines.len() && !lines[index].trim_start().starts_with(fence) {
                code.push(lines[index]);
                index += 1;
            }
            index += 1;
            builder.code(&code.join("\n"), (!language.is_empty()).then_some(language));
            continue;
        }
        if trimmed.is_empty() {
            flush(builder, &mut paragraph);
            index += 1;
            continue;
        }
        if let Some((level, text)) = heading(trimmed) {
            flush(builder, &mut paragraph);
            if !text.is_empty() {
                let span = builder.markdown_span(text);
                builder.push_block(proto::block::Kind::Heading(proto::BlockHeading {
                    text: Some(span),
                    level,
                }));
            }
            index += 1;
            continue;
        }
        if is_rule(trimmed) {
            flush(builder, &mut paragraph);
            index += 1;
            continue;
        }
        if let Some(first) = list_item(line) {
            flush(builder, &mut paragraph);
            let mut items = vec![first];
            index += 1;
            while index < lines.len() {
                let next = lines[index];
                if let Some(item) = list_item(next) {
                    items.push(item);
                } else if !next.trim().is_empty()
                    && next.starts_with([' ', '\t'])
                    && fence(next.trim()).is_none()
                    && let Some(last) = items.last_mut()
                {
                    // A wrapped line of the item above.
                    last.text.push(' ');
                    last.text.push_str(next.trim());
                } else {
                    break;
                }
                index += 1;
            }
            write_list(builder, &items);
            continue;
        }
        paragraph.push(
            trimmed
                .trim_start_matches("> ")
                .trim_start_matches('>')
                .to_owned(),
        );
        index += 1;
    }
    flush(builder, &mut paragraph);
}

struct Item {
    ordered: Option<i64>,
    checked: Option<bool>,
    text: String,
}

fn write_list(builder: &mut DocBuilder, items: &[Item]) {
    let start = items.first().and_then(|item| item.ordered);
    let mut number = start.unwrap_or(1);
    let items = items
        .iter()
        .map(|item| {
            let marker = match (start, item.checked) {
                (_, Some(true)) => "[x] ".to_owned(),
                (_, Some(false)) => "[ ] ".to_owned(),
                (Some(_), None) => format!("{number}. "),
                (None, None) => "• ".to_owned(),
            };
            number += 1;
            builder.push_raw(&marker);
            let span = builder.markdown_span(if item.text.is_empty() {
                " "
            } else {
                &item.text
            });
            proto::BlockListItem {
                children: vec![proto::Block {
                    kind: Some(proto::block::Kind::Paragraph(span)),
                }],
                checked: item.checked,
            }
        })
        .collect();
    let kind = if start.is_some() {
        proto::block_list::Kind::Ordered
    } else {
        proto::block_list::Kind::Unordered
    };
    builder.push_block(proto::block::Kind::List(proto::BlockList {
        kind: kind as i32,
        start: start.filter(|start| *start != 1),
        items,
        is_rtl: None,
    }));
}

fn fence(trimmed: &str) -> Option<&'static str> {
    ["```", "~~~"]
        .into_iter()
        .find(|fence| trimmed.starts_with(fence))
}

fn heading(trimmed: &str) -> Option<(u32, &str)> {
    let level = trimmed
        .chars()
        .take_while(|character| *character == '#')
        .count();
    if !(1..=6).contains(&level) {
        return None;
    }
    let rest = &trimmed[level..];
    rest.starts_with(' ')
        .then(|| (level as u32, rest.trim().trim_end_matches('#').trim()))
}

fn is_rule(trimmed: &str) -> bool {
    trimmed.len() >= 3
        && ["-", "*", "_"].iter().any(|mark| {
            trimmed
                .chars()
                .filter(|character| !character.is_whitespace())
                .all(|character| character.to_string() == *mark)
        })
}

fn list_item(line: &str) -> Option<Item> {
    let trimmed = line.trim_start();
    let (ordered, rest) = if let Some(rest) = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
        .or_else(|| trimmed.strip_prefix("+ "))
    {
        (None, rest)
    } else {
        let digits: String = trimmed.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() || digits.len() > 9 {
            return None;
        }
        let rest = &trimmed[digits.len()..];
        let rest = rest
            .strip_prefix(". ")
            .or_else(|| rest.strip_prefix(") "))?;
        (digits.parse().ok(), rest)
    };
    let (checked, text) = if let Some(text) = rest.strip_prefix("[ ] ") {
        (Some(false), text)
    } else if let Some(text) = rest
        .strip_prefix("[x] ")
        .or_else(|| rest.strip_prefix("[X] "))
    {
        (Some(true), text)
    } else {
        (None, rest)
    };
    Some(Item {
        ordered,
        checked,
        text: text.trim().to_owned(),
    })
}

/// Plain text and the inline styles over it, in UTF-16 units of `text`.
#[derive(Debug, Default)]
pub(crate) struct Styled {
    pub text: String,
    pub entities: Vec<proto::MessageEntity>,
}

/// Deepest emphasis inside emphasis; past it, markers read as written.
const MAX_NESTING: usize = 4;

/// Inline Markdown as Inline styles it: `code`, **bold**, *italic*,
/// ~~strikethrough~~ and [links](https://…). An unclosed marker stays as
/// written, so prose still streaming reads as typed.
pub(crate) fn inline(markdown: &str) -> Styled {
    let mut styled = Styled::default();
    let mut utf16 = 0;
    write_inline(markdown, &mut styled, &mut utf16, 0);
    styled
        .entities
        .sort_by_key(|entity| (entity.offset, -entity.length));
    styled
}

fn write_inline(source: &str, out: &mut Styled, utf16: &mut i64, depth: usize) {
    use proto::message_entity::Type;
    let mut rest = source;
    let mut previous: Option<char> = None;
    while let Some(character) = rest.chars().next() {
        let next = rest[character.len_utf8()..].chars().next();
        // A backslash keeps the punctuation after it literal.
        if character == '\\'
            && let Some(escaped) = next.filter(char::is_ascii_punctuation)
        {
            push(out, utf16, &rest[1..1 + escaped.len_utf8()]);
            rest = &rest[1 + escaped.len_utf8()..];
            previous = Some(escaped);
            continue;
        }
        if character == '`' {
            let ticks = rest.len() - rest.trim_start_matches('`').len();
            if let Some(close) = code_close(&rest[ticks..], ticks) {
                let code = &rest[ticks..ticks + close];
                let code = match code
                    .strip_prefix(' ')
                    .and_then(|code| code.strip_suffix(' '))
                {
                    Some(inner) if !inner.trim().is_empty() => inner,
                    _ => code,
                };
                let start = *utf16;
                push(out, utf16, code);
                entity(out, Type::Code, start, *utf16 - start, None);
                rest = &rest[ticks + close + ticks..];
                previous = Some('`');
                continue;
            }
            push(out, utf16, &rest[..ticks]);
            rest = &rest[ticks..];
            previous = Some('`');
            continue;
        }
        if depth < MAX_NESTING
            && let Some((marker, kind)) = emphasis(rest, previous)
            && let Some(close) = emphasis_close(&rest[marker.len()..], marker)
        {
            let inner = &rest[marker.len()..marker.len() + close];
            let start = *utf16;
            write_inline(inner, out, utf16, depth + 1);
            entity(out, kind, start, *utf16 - start, None);
            rest = &rest[marker.len() + close + marker.len()..];
            previous = marker.chars().last();
            continue;
        }
        if character == '['
            && depth < MAX_NESTING
            && let Some((label, url, used)) = link(rest)
        {
            let start = *utf16;
            write_inline(label, out, utf16, depth + 1);
            entity(out, Type::TextUrl, start, *utf16 - start, Some(url));
            rest = &rest[used..];
            previous = Some(')');
            continue;
        }
        push(out, utf16, &rest[..character.len_utf8()]);
        rest = &rest[character.len_utf8()..];
        previous = Some(character);
    }
}

fn push(out: &mut Styled, utf16: &mut i64, text: &str) {
    out.text.push_str(text);
    *utf16 += text.encode_utf16().count() as i64;
}

fn entity(
    out: &mut Styled,
    kind: proto::message_entity::Type,
    offset: i64,
    length: i64,
    url: Option<&str>,
) {
    if length <= 0 {
        return;
    }
    out.entities.push(proto::MessageEntity {
        r#type: kind as i32,
        offset,
        length,
        entity: url.map(|url| {
            proto::message_entity::Entity::TextUrl(proto::message_entity::MessageEntityTextUrl {
                url: url.to_owned(),
            })
        }),
    });
}

/// Where a code span opened by `ticks` backticks closes: the next run of
/// exactly that many, on any line of the paragraph.
fn code_close(rest: &str, ticks: usize) -> Option<usize> {
    let mut index = 0;
    while let Some(found) = rest[index..].find('`') {
        let start = index + found;
        let run = rest[start..].len() - rest[start..].trim_start_matches('`').len();
        if run == ticks && start > 0 {
            return Some(start);
        }
        index = start + run;
    }
    None
}

/// The emphasis marker that opens at the start of `rest`, if one can.
fn emphasis(
    rest: &str,
    previous: Option<char>,
) -> Option<(&'static str, proto::message_entity::Type)> {
    use proto::message_entity::Type;
    let (marker, kind) = [
        ("**", Type::Bold),
        ("__", Type::Bold),
        ("~~", Type::Strikethrough),
        ("*", Type::Italic),
        ("_", Type::Italic),
    ]
    .into_iter()
    .find(|(marker, _)| rest.starts_with(marker))?;
    let after = rest[marker.len()..].chars().next()?;
    // Opens before text, never inside a longer run of the same marker (a
    // glob's `**/*`) or before a space.
    let mark = marker.chars().next();
    if after.is_whitespace()
        || marker.len() == 1 && (rest[1..].starts_with(marker) || previous == mark)
    {
        return None;
    }
    // An underscore inside a word, as in snake_case, is a letter.
    if marker.starts_with('_') && previous.is_some_and(char::is_alphanumeric) {
        return None;
    }
    Some((marker, kind))
}

/// Where emphasis opened by `marker` closes in `rest`: the same marker right
/// after text, and for underscores not inside a word.
fn emphasis_close(rest: &str, marker: &str) -> Option<usize> {
    let mut index = 0;
    while let Some(found) = rest[index..].find(marker) {
        let start = index + found;
        let before = rest[..start].chars().last();
        let after = rest[start + marker.len()..].chars().next();
        let doubled = marker.len() == 1 && after.is_some_and(|after| marker.starts_with(after));
        let in_word = marker.starts_with('_') && after.is_some_and(char::is_alphanumeric);
        if start > 0 && before.is_some_and(|before| !before.is_whitespace()) && !doubled && !in_word
        {
            return Some(start);
        }
        index = start + marker.len();
        if doubled {
            index += marker.len();
        }
    }
    None
}

/// `[label](https://…)` at the start of `rest`: the label, the URL and the
/// bytes used. Only web and mail links; anything else reads as written.
fn link(rest: &str) -> Option<(&str, &str, usize)> {
    let close = rest.find("](")?;
    let label = &rest[1..close];
    if label.is_empty() || label.contains(['[', ']', '\n']) {
        return None;
    }
    let after = &rest[close + 2..];
    let end = after.find(')')?;
    let url = &after[..end];
    let allowed = ["https://", "http://", "mailto:"]
        .iter()
        .any(|scheme| url.starts_with(scheme));
    if !allowed || url.contains(char::is_whitespace) {
        return None;
    }
    Some((label, url, close + 2 + end + 1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::v2::blocks::slice;
    use proto::message_entity::{Entity, Type};

    fn text_at(text: &str, offset: i64, length: i64) -> Option<String> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let end = usize::try_from(offset + length).ok()?;
        String::from_utf16(units.get(usize::try_from(offset).ok()?..end)?).ok()
    }

    /// The plain text and each style as (type, styled text).
    fn styled(markdown: &str) -> (String, Vec<(Type, String)>) {
        let styled = inline(markdown);
        let entities = styled
            .entities
            .iter()
            .map(|entity| {
                (
                    Type::try_from(entity.r#type).expect("type"),
                    text_at(&styled.text, entity.offset, entity.length).expect("in range"),
                )
            })
            .collect();
        (styled.text, entities)
    }

    #[test]
    fn inline_markdown_becomes_plain_text_with_styles() {
        assert_eq!(
            styled("The `app_error` issue is **not** new, see *Sentry*."),
            (
                "The app_error issue is not new, see Sentry.".to_owned(),
                vec![
                    (Type::Code, "app_error".to_owned()),
                    (Type::Bold, "not".to_owned()),
                    (Type::Italic, "Sentry".to_owned()),
                ]
            )
        );
        assert_eq!(
            styled("**Fix `parse()` first**, then ~~ship~~ wait."),
            (
                "Fix parse() first, then ship wait.".to_owned(),
                vec![
                    (Type::Bold, "Fix parse() first".to_owned()),
                    (Type::Code, "parse()".to_owned()),
                    (Type::Strikethrough, "ship".to_owned()),
                ]
            )
        );
        assert_eq!(
            styled("Use ``a `tick` here`` now."),
            (
                "Use a `tick` here now.".to_owned(),
                vec![(Type::Code, "a `tick` here".to_owned())]
            )
        );
    }

    #[test]
    fn links_carry_their_url_and_only_web_links_count() {
        let parsed = inline("See [the docs](https://inline.chat/docs) or [x](file:///etc).");
        assert_eq!(parsed.text, "See the docs or [x](file:///etc).");
        assert_eq!(parsed.entities.len(), 1);
        assert_eq!(
            parsed.entities[0].entity,
            Some(Entity::TextUrl(
                proto::message_entity::MessageEntityTextUrl {
                    url: "https://inline.chat/docs".to_owned(),
                }
            ))
        );
    }

    #[test]
    fn code_like_prose_and_unclosed_markers_read_as_written() {
        for text in [
            "Edit snake_case_name and __init__ alone",
            "Glob src/**/*.rs and *.ts files",
            "Compute 2 * 3 * 4",
            "Still streaming `unclosed and **bold",
            "Escaped \\*stars\\* stay",
        ] {
            let (plain, entities) = styled(text);
            let wanted = match text {
                "Edit snake_case_name and __init__ alone" => {
                    vec![(Type::Bold, "init".to_owned())]
                }
                _ => Vec::new(),
            };
            assert_eq!(entities, wanted, "{text}");
            if text.starts_with("Escaped") {
                assert_eq!(plain, "Escaped *stars* stay");
            } else if !text.starts_with("Edit") {
                assert_eq!(plain, text);
            }
        }
    }

    #[test]
    fn styles_count_utf16_units() {
        let parsed = inline("🚀 **go** `now`");
        assert_eq!(parsed.text, "🚀 go now");
        let ranges: Vec<(i64, i64)> = parsed
            .entities
            .iter()
            .map(|entity| (entity.offset, entity.length))
            .collect();
        assert_eq!(ranges, [(3, 2), (6, 3)]);
    }

    #[test]
    fn a_plan_becomes_headings_lists_code_and_paragraphs() {
        let mut builder = DocBuilder::new();
        write(
            &mut builder,
            "## Steps\n\n1. Read **parser.ts**\n2. Fix the\n   empty case\n- [x] done\n\n```ts\nparse(\"\")\n```\nThen `cargo test`.",
        );
        let doc = builder.finish();
        assert_eq!(
            doc.text,
            "Steps\n1. Read parser.ts\n2. Fix the empty case\n[x] done\nparse(\"\")\nThen cargo test."
        );
        let styled: Vec<(i32, Option<String>)> = doc
            .entities
            .iter()
            .map(|entity| {
                (
                    entity.r#type,
                    text_at(&doc.text, entity.offset, entity.length),
                )
            })
            .collect();
        assert_eq!(
            styled,
            [
                (Type::Bold as i32, Some("parser.ts".to_owned())),
                (Type::Code as i32, Some("cargo test".to_owned())),
            ]
        );
        let kinds: Vec<&str> = doc
            .blocks
            .iter()
            .map(|block| match block.kind.as_ref().expect("kind") {
                proto::block::Kind::Heading(_) => "heading",
                proto::block::Kind::List(_) => "list",
                proto::block::Kind::Code(_) => "code",
                proto::block::Kind::Paragraph(_) => "paragraph",
                _ => "other",
            })
            .collect();
        // The task item continues the numbered list, as Markdown reads it.
        assert_eq!(kinds, ["heading", "list", "code", "paragraph"]);
        let Some(proto::block::Kind::List(list)) = &doc.blocks[1].kind else {
            panic!("list");
        };
        assert_eq!(list.items.len(), 3);
        assert_eq!(list.items[2].checked, Some(true));
        let Some(proto::block::Kind::Paragraph(span)) = &list.items[1].children[0].kind else {
            panic!("item");
        };
        assert_eq!(
            slice(&doc.text, span).as_deref(),
            Some("Fix the empty case")
        );
    }
}
