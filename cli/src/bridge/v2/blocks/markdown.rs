//! Agent Markdown (a plan's body) as blocks inside another block.
//!
//! A message whose text is Markdown is parsed by Inline itself, but a block's
//! children are built here, so this is the 90/10 of it, line by line:
//! headings, fenced code, bullet, numbered and task lists, and paragraphs.
//! Emphasis markers are dropped; inline code keeps its backticks.

use inline_protocol::proto;

use crate::bridge::v2::doc::DocBuilder;

/// Writes `markdown` as blocks.
pub(crate) fn write(builder: &mut DocBuilder, markdown: &str) {
    let lines: Vec<&str> = markdown.lines().collect();
    let mut paragraph: Vec<String> = Vec::new();
    let mut index = 0;
    let flush = |builder: &mut DocBuilder, paragraph: &mut Vec<String>| {
        if !paragraph.is_empty() {
            builder.paragraph(&paragraph.join("\n"));
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
            builder.heading(&inline(text), level);
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
        paragraph.push(inline(
            trimmed.trim_start_matches("> ").trim_start_matches('>'),
        ));
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
            let text = inline(&item.text);
            let span = builder.span(if text.is_empty() { " " } else { &text });
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

/// Drops emphasis markers; the rest reads as written.
fn inline(text: &str) -> String {
    text.replace("**", "").replace("__", "").trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::v2::blocks::slice;

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
            "Steps\n1. Read parser.ts\n2. Fix the empty case\n[x] done\nparse(\"\")\nThen `cargo test`."
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
