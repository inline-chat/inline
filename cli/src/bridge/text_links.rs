//! Preserve Inline identities in provider text without exposing entity offsets.

use std::ops::Range;

use inline_client::MessageEntityRecord;

pub(super) fn inline_mention(label: &str, user_id: i64, agent_id: Option<i64>) -> String {
    let label = if label.starts_with('@') {
        label.to_string()
    } else {
        format!("@{label}")
    };
    let mut target = format!("in://user/{user_id}");
    if let Some(agent_id) = agent_id.filter(|id| *id > 0) {
        target.push_str(&format!("?agent_id={agent_id}"));
    }
    markdown_link(&label, &target)
}

/// Ranges refer to the original text, before trimming or removing an address.
/// Only a leading mention of this bot is routing syntax. References to the bot
/// within the request, and a mention-only ping, retain their identity as links.
pub(super) fn render_inline_text(
    text: &str,
    entities: &[MessageEntityRecord],
    addressed_bot: Option<i64>,
) -> String {
    if entities.is_empty() {
        return text.to_string();
    }
    let mut boundaries = vec![Some(0)];
    for (byte, character) in text.char_indices() {
        if character.len_utf16() == 2 {
            boundaries.push(None);
        }
        boundaries.push(Some(byte + character.len_utf8()));
    }
    let ranges = entities
        .iter()
        .filter_map(|entity| {
            let start = usize::try_from(entity.offset).ok()?;
            let length = usize::try_from(entity.length)
                .ok()
                .filter(|length| *length > 0)?;
            let end = start.checked_add(length)?;
            Some((
                boundaries.get(start).copied().flatten()?
                    ..boundaries.get(end).copied().flatten()?,
                entity,
            ))
        })
        .collect::<Vec<_>>();
    let mut links = ranges
        .iter()
        .filter_map(|(range, entity)| {
            let label = &text[range.clone()];
            if label.trim().is_empty() {
                return None;
            }
            let link = match entity.kind.as_str() {
                "TYPE_MENTION" => {
                    let user_id = entity.user_id?.get();
                    if user_id <= 0 {
                        return None;
                    }
                    inline_mention(label, user_id, entity.agent_id.map(|id| id.get()))
                }
                "TYPE_THREAD" => {
                    let chat_id = entity.chat_id?.get();
                    if chat_id <= 0 {
                        return None;
                    }
                    markdown_link(label, &format!("in://chat/{chat_id}"))
                }
                "TYPE_GROUP_MENTION" => {
                    let group_id = entity.group_id?.get();
                    if group_id <= 0 {
                        return None;
                    }
                    // Group links use the existing server mention grammar.
                    markdown_link(label, &format!("inline://group/{group_id}"))
                }
                "TYPE_TEXT_URL" => {
                    let target = entity.value.as_deref()?;
                    let parsed = url::Url::parse(target).ok()?;
                    if !matches!(parsed.scheme(), "in" | "inline" | "http" | "https")
                        || target.contains(['\r', '\n'])
                    {
                        return None;
                    }
                    markdown_link(label, target)
                }
                _ => return None,
            };
            // Opaque code/formulas must stay literal even with conflicting metadata.
            if ranges.iter().any(|(other, entity)| {
                matches!(entity.kind.as_str(), "TYPE_CODE" | "TYPE_PRE" | "TYPE_MATH")
                    && overlaps(range, other)
            }) {
                return None;
            }
            Some((range.clone(), *entity, link))
        })
        .collect::<Vec<_>>();
    links.sort_by_key(|(range, _, _)| (range.start, range.end));
    let mut output = String::with_capacity(text.len());
    let mut cursor = 0;
    for (index, (range, entity, link)) in links.iter().enumerate() {
        if range.start < cursor {
            continue;
        }
        // Ambiguous overlapping identities preserve the original visible text.
        if links
            .iter()
            .enumerate()
            .any(|(other_index, (other, _, _))| index != other_index && overlaps(range, other))
        {
            continue;
        }
        let suffix = &text[range.end..];
        let is_address = entity.kind == "TYPE_MENTION"
            && addressed_bot.is_some_and(|id| entity.user_id.is_some_and(|user| user.get() == id))
            && text[..range.start].trim().is_empty()
            && suffix.chars().next().is_some_and(|character| {
                character.is_whitespace() || matches!(character, ',' | ':')
            });
        let request = suffix
            .strip_prefix([',', ':'])
            .unwrap_or(suffix)
            .trim_start();
        if is_address && !request.is_empty() {
            cursor = text.len() - request.len();
            continue;
        }
        output.push_str(&text[cursor..range.start]);
        output.push_str(link);
        cursor = range.end;
    }
    output.push_str(&text[cursor..]);
    output
}

fn overlaps(left: &Range<usize>, right: &Range<usize>) -> bool {
    left.start < right.end && right.start < left.end
}

fn markdown_link(label: &str, target: &str) -> String {
    let mut escaped = String::with_capacity(label.len());
    for character in label.chars() {
        if matches!(character, '\r' | '\n') {
            escaped.push_str(if character == '\n' { "&#10;" } else { "&#13;" });
            continue;
        }
        if matches!(
            character,
            '\\' | '[' | ']' | '`' | '*' | '_' | '<' | '>' | '!' | '&' | '~' | '=' | '$' | '|'
        ) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    let mut destination = String::with_capacity(target.len());
    for character in target.chars() {
        if matches!(character, '\\' | '(' | ')' | '<' | '>' | '&') {
            destination.push('\\');
        }
        destination.push(character);
    }
    if target.contains([' ', '\t']) {
        destination = format!("<{destination}>");
    }
    format!("[{escaped}]({destination})")
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use inline_client::InlineId;

    pub(in crate::bridge) fn entity(
        text: &str,
        label: &str,
        kind: &str,
        id: i64,
    ) -> MessageEntityRecord {
        let start = text.find(label).expect("entity label");
        MessageEntityRecord {
            kind: kind.to_string(),
            offset: text[..start].encode_utf16().count() as i64,
            length: label.encode_utf16().count() as i64,
            user_id: (kind == "TYPE_MENTION").then_some(InlineId::new(id)),
            chat_id: (kind == "TYPE_THREAD").then_some(InlineId::new(id)),
            agent_id: None,
            group_id: (kind == "TYPE_GROUP_MENTION").then_some(InlineId::new(id)),
            value: None,
        }
    }

    #[test]
    fn strips_only_the_leading_bot_address_and_keeps_other_identities() {
        let text = "  @Mo’s Codex: 😀 ask @Dena about Planning";
        let entities = [
            entity(text, "Planning", "TYPE_THREAD", 456),
            entity(text, "@Dena", "TYPE_MENTION", 123),
            entity(text, "@Mo’s Codex", "TYPE_MENTION", 99),
        ];
        assert_eq!(
            render_inline_text(text, &entities, Some(99)),
            "😀 ask [@Dena](in://user/123) about [Planning](in://chat/456)"
        );
        // Conversation history keeps the mention, so the quoted addressing survives.
        assert!(render_inline_text(text, &entities, None).contains("[@Mo’s Codex](in://user/99)"));
    }

    #[test]
    fn retains_meaningful_bot_references_pings_and_unstructured_text() {
        for text in [
            "@Mo’s Codex",
            "@Mo’s Codex’s behavior",
            "rename @Mo’s Codex please",
        ] {
            let entities = [entity(text, "@Mo’s Codex", "TYPE_MENTION", 99)];
            assert!(
                render_inline_text(text, &entities, Some(99))
                    .contains("[@Mo’s Codex](in://user/99)")
            );
        }
        let text = "@Mo’s Codex hi";
        assert_eq!(render_inline_text(text, &[], Some(99)), text);
        let entities = [entity(text, "@Mo’s Codex", "TYPE_MENTION", 98)];
        assert_eq!(
            render_inline_text(text, &entities, Some(99)),
            "[@Mo’s Codex](in://user/98) hi"
        );
    }

    #[test]
    fn retains_agent_and_message_destinations_and_escapes_labels() {
        let text = "ask @Data [Analyst] about this message";
        let mut agent = entity(text, "@Data [Analyst]", "TYPE_MENTION", 123);
        agent.agent_id = Some(InlineId::new(7));
        let mut message = entity(text, "this message", "TYPE_TEXT_URL", 0);
        message.value = Some("in://chat/456/message/9".to_string());
        assert_eq!(
            render_inline_text(text, &[agent, message], None),
            "ask [@Data \\[Analyst\\]](in://user/123?agent_id=7) about [this message](in://chat/456/message/9)"
        );
    }

    #[test]
    fn malformed_overlapping_and_opaque_ranges_preserve_text() {
        let text = "😀 @Dena";
        let mention = entity(text, "@Dena", "TYPE_MENTION", 123);
        let mut malformed = mention.clone();
        for (offset, length) in [(-1, 2), (1, 1), (3, i64::MAX), (3, 0), (100, 3)] {
            malformed.offset = offset;
            malformed.length = length;
            assert_eq!(
                render_inline_text(text, &[malformed.clone()], Some(99)),
                text
            );
        }
        assert_eq!(
            render_inline_text(text, &[mention.clone(), mention.clone()], None),
            text
        );
        for kind in ["TYPE_CODE", "TYPE_PRE", "TYPE_MATH"] {
            let opaque = entity(text, "@Dena", kind, 0);
            assert_eq!(
                render_inline_text(text, &[mention.clone(), opaque], None),
                text
            );
        }
    }

    #[test]
    fn preserves_group_identity_and_literal_label_and_destination_bytes() {
        assert_eq!(
            inline_mention("a ==B==", 123, None),
            "[@a \\=\\=B\\=\\=](in://user/123)"
        );
        let text = "ask @eng and @A &amp; B about First\n\nSecond";
        let entities = [
            entity(text, "@eng", "TYPE_GROUP_MENTION", 8),
            entity(text, "@A &amp; B", "TYPE_MENTION", 123),
            entity(text, "First\n\nSecond", "TYPE_THREAD", 456),
        ];
        assert_eq!(
            render_inline_text(text, &entities, None),
            "ask [@eng](inline://group/8) and [@A \\&amp; B](in://user/123) about [First&#10;&#10;Second](in://chat/456)"
        );
        let mut link = entity("doc", "doc", "TYPE_TEXT_URL", 0);
        link.value = Some("https://example.com/a(b)?x=&amp;&y=1".to_string());
        assert_eq!(
            render_inline_text("doc", &[link], None),
            "[doc](https://example.com/a\\(b\\)?x=\\&amp;\\&y=1)"
        );
    }
}
