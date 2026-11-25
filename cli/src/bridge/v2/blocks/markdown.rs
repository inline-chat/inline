//! Agent Markdown (a plan's body, prose between tool calls) as blocks inside
//! another block.
//!
//! A message whose text is Markdown is parsed by Inline itself, but a block's
//! children are built here, so this is the 90/10 of it, line by line:
//! headings, fenced code, bullet, numbered and task lists, and paragraphs.
//! Inline code, bold, italic, strikethrough and links become message entities
//! over the plain text, as Inline styles a Markdown message.

use inline_agent_bridge::widget::Fence;
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
        if let Some(fence) = Fence::opening(trimmed) {
            flush(builder, &mut paragraph);
            // The info string: what follows the fence's run of markers.
            let language = trimmed.trim_start_matches(['`', '~']).trim();
            let mut code = Vec::new();
            index += 1;
            // Only a run at least as long as the opener closes it, so a
            // longer fence can show a shorter one inside.
            while index < lines.len() && !fence.closed_by(lines[index].trim_start()) {
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
        if let Some(alignments) = lines
            .get(index + 1)
            .and_then(|next| table_alignments(line, next))
        {
            flush(builder, &mut paragraph);
            let mut rows = vec![table_cells(line)];
            index += 2;
            while index < lines.len() && lines[index].trim_start().starts_with('|') {
                rows.push(table_cells(lines[index]));
                index += 1;
            }
            write_table(builder, &rows, alignments);
            continue;
        }
        if let Some(first) = list_item(line) {
            flush(builder, &mut paragraph);
            let indent = indent_of(line);
            let mut items = vec![first];
            index += 1;
            while index < lines.len() {
                let next = lines[index];
                if let Some(item) = list_item(next) {
                    if indent_of(next) > indent
                        && let Some(last) = items.last_mut()
                    {
                        // A nested item stays inside the item above, on its
                        // own line, so it neither renumbers the list nor
                        // reads as a sibling.
                        last.text.push('\n');
                        last.text.push_str(&nested_marker(&item));
                        last.text.push_str(&item.text);
                    } else {
                        items.push(item);
                    }
                } else if !next.trim().is_empty()
                    && next.starts_with([' ', '\t'])
                    && Fence::opening(next.trim()).is_none()
                    && let Some(last) = items.last_mut()
                {
                    // A wrapped line of the item above.
                    last.text.push(' ');
                    last.text.push_str(next.trim());
                } else if next.trim().is_empty()
                    && lines[index + 1..]
                        .iter()
                        .find(|line| !line.trim().is_empty())
                        .is_some_and(|line| {
                            list_item(line).is_some_and(|_| indent_of(line) >= indent)
                        })
                {
                    // A loose list: a blank line between its items, as models
                    // write plans ("1. Step\n\n   - detail").
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

/// A GFM table's column alignments, when `header` and `separator` open one
/// (`| a | b |` over `|---|:--:|`).
fn table_alignments(header: &str, separator: &str) -> Option<Vec<proto::block_table::Alignment>> {
    use proto::block_table::Alignment;
    if !header.contains('|') || !separator.contains('-') {
        return None;
    }
    let columns = table_cells(header).len();
    let alignments = table_cells(separator)
        .into_iter()
        .map(|cell| {
            let cell = cell.trim();
            let dashes = cell.trim_matches(':');
            (!dashes.is_empty() && dashes.chars().all(|c| c == '-')).then(|| {
                match (cell.starts_with(':'), cell.ends_with(':')) {
                    (true, true) => Alignment::Center,
                    (true, false) => Alignment::Left,
                    (false, true) => Alignment::Right,
                    (false, false) => Alignment::Unspecified,
                }
            })
        })
        .collect::<Option<Vec<_>>>()?;
    (columns > 0 && alignments.len() == columns).then_some(alignments)
}

/// A table row's cells: split on `|` outside inline code, `\|` kept.
fn table_cells(line: &str) -> Vec<String> {
    let line = line.trim();
    let line = line.strip_prefix('|').unwrap_or(line);
    let line = line.strip_suffix('|').unwrap_or(line);
    let mut cells = vec![String::new()];
    let mut code = false;
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '\\' if chars.peek() == Some(&'|') => {
                cells.last_mut().expect("cell").push('|');
                chars.next();
            }
            '`' => {
                code = !code;
                cells.last_mut().expect("cell").push(character);
            }
            '|' if !code => cells.push(String::new()),
            _ => cells.last_mut().expect("cell").push(character),
        }
    }
    cells
        .into_iter()
        .map(|cell| cell.trim().to_owned())
        .collect()
}

/// A table block, each row also a line of text ("a | b") for clients that
/// draw text only. Every row gets exactly one cell per column.
fn write_table(
    builder: &mut DocBuilder,
    rows: &[Vec<String>],
    alignments: Vec<proto::block_table::Alignment>,
) {
    let columns = alignments.len();
    let rows = rows
        .iter()
        .map(|row| {
            let cells = (0..columns)
                .map(|column| {
                    if column > 0 {
                        builder.push_raw(" | ");
                    }
                    let text = row.get(column).map(String::as_str).unwrap_or("");
                    builder.markdown_inline_span(if text.is_empty() { " " } else { text })
                })
                .collect();
            builder.newline();
            proto::BlockTableRow { cells }
        })
        .collect();
    builder.push_block(proto::block::Kind::Table(proto::BlockTable {
        rows,
        alignments: alignments
            .into_iter()
            .map(|alignment| alignment as i32)
            .collect(),
        is_rtl: None,
    }));
}

/// Leading width of a line, a tab as four columns.
fn indent_of(line: &str) -> usize {
    line.chars()
        .take_while(|character| matches!(character, ' ' | '\t'))
        .map(|character| if character == '\t' { 4 } else { 1 })
        .sum()
}

/// How a nested item reads inside its parent's line: its own marker,
/// indented.
fn nested_marker(item: &Item) -> String {
    match (item.checked, item.ordered) {
        (Some(true), _) => "    [x] ".to_owned(),
        (Some(false), _) => "    [ ] ".to_owned(),
        (None, Some(number)) => format!("    {number}. "),
        (None, None) => "    ◦ ".to_owned(),
    }
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
    #[test]
    fn nested_items_stay_inside_their_item_and_keep_the_numbers() {
        let mut builder = DocBuilder::new();
        write(
            &mut builder,
            "1. Update the schema\n   - add the column\n   - backfill\n2. Ship the client\n3. Remove the flag",
        );
        let doc = builder.finish();
        assert_eq!(
            doc.text,
            "1. Update the schema\n    ◦ add the column\n    ◦ backfill\n2. Ship the client\n3. Remove the flag"
        );
        let Some(proto::block::Kind::List(list)) = &doc.blocks[0].kind else {
            panic!("list");
        };
        assert_eq!(list.items.len(), 3);
    }

    #[test]
    fn a_longer_fence_shows_a_shorter_one_and_an_info_line_does_not_close() {
        let mut builder = DocBuilder::new();
        write(
            &mut builder,
            "````markdown\n```rust\nfn main() {}\n```\n````\nAfter.",
        );
        let doc = builder.finish();
        let Some(proto::block::Kind::Code(code)) = &doc.blocks[0].kind else {
            panic!("code: {:?}", doc.blocks);
        };
        assert_eq!(code.language.as_deref(), Some("markdown"));
        assert_eq!(doc.blocks.len(), 2, "{:?}", doc.blocks);
        assert!(
            doc.text.contains("```rust\nfn main() {}\n```"),
            "{}",
            doc.text
        );
        // An open ``` block is not closed by a "```rust" line.
        let mut builder = DocBuilder::new();
        write(&mut builder, "```\na\n```rust\nb\n```\nAfter.");
        let doc = builder.finish();
        assert_eq!(doc.blocks.len(), 2, "{:?}", doc.blocks);
        assert!(doc.text.starts_with("a\n```rust\nb"), "{}", doc.text);
    }

    #[test]
    fn a_loose_list_with_blank_lines_stays_one_list() {
        let mut builder = DocBuilder::new();
        write(
            &mut builder,
            "1. Update `parse` in `src/parser.py`.\n\n   - Return `[]` for empty text.\n   - Keep the error otherwise.\n\n2. Run the tests.\n\nThen ship it.",
        );
        let doc = builder.finish();
        let Some(proto::block::Kind::List(list)) = &doc.blocks[0].kind else {
            panic!("list: {:?}", doc.blocks);
        };
        assert_eq!(list.items.len(), 2, "{}", doc.text);
        assert!(doc.text.starts_with("1. Update parse in src/parser.py.\n    ◦ Return [] for empty text.\n    ◦ Keep the error otherwise.\n2. Run the tests."), "{}", doc.text);
        assert!(matches!(
            doc.blocks[1].kind,
            Some(proto::block::Kind::Paragraph(_))
        ));
    }

    #[test]
    fn a_table_becomes_a_table_block_with_its_alignments() {
        let mut builder = DocBuilder::new();
        write(
            &mut builder,
            "Found these:\n\n| File | Line | Kind |\n|---|--:|:---:|\n| `src/parser.py` | 1 | Definition |\n| tests/test_parser.py | 8 | Call `a\\|b` |\n| short |\n\nDone.",
        );
        let doc = builder.finish();
        let kinds: Vec<&str> = doc
            .blocks
            .iter()
            .map(|block| match block.kind.as_ref().expect("kind") {
                proto::block::Kind::Table(_) => "table",
                proto::block::Kind::Paragraph(_) => "paragraph",
                _ => "other",
            })
            .collect();
        assert_eq!(kinds, ["paragraph", "table", "paragraph"], "{}", doc.text);
        let Some(proto::block::Kind::Table(table)) = &doc.blocks[1].kind else {
            panic!("table");
        };
        assert_eq!(table.rows.len(), 4);
        assert!(table.rows.iter().all(|row| row.cells.len() == 3));
        use proto::block_table::Alignment;
        assert_eq!(
            table.alignments,
            [
                Alignment::Unspecified as i32,
                Alignment::Right as i32,
                Alignment::Center as i32
            ]
        );
        let cell = |row: usize, column: usize| slice(&doc.text, &table.rows[row].cells[column]);
        assert_eq!(cell(0, 0).as_deref(), Some("File"));
        // Inline code stays styled, and an escaped pipe stays in its cell.
        assert_eq!(cell(1, 0).as_deref(), Some("src/parser.py"));
        assert_eq!(cell(2, 2).as_deref(), Some("Call a|b"));
        assert!(doc.text.contains("File | Line | Kind\n"), "{}", doc.text);
        // A pipe line without a separator under it is not a table.
        let mut builder = DocBuilder::new();
        write(&mut builder, "a | b\nplain");
        assert!(
            builder
                .finish()
                .blocks
                .iter()
                .all(|block| !matches!(block.kind, Some(proto::block::Kind::Table(_))))
        );
    }
}
