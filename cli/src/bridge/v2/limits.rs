//! Inline's message limits, as the server enforces them, and a message's size
//! against them.
//!
//! The server refuses a bot message over any of these with a bare
//! `BadRequest`, so the renderer measures what it builds and continues in a
//! new message before a limit, as v1 did.
//!
//! Mirrors `server/src/modules/encryption/limits.ts` (text) and
//! `server/src/modules/message/blockContent.ts` (`blockContentLimits` and the
//! validator's walk). `limits_match_the_server` keeps the numbers in step.

use inline_protocol::proto;

use super::doc::Doc;

/// `MAX_MESSAGE_TEXT_UTF16_UNITS`.
pub(crate) const MAX_TEXT_UTF16: usize = 100_000;
/// `MAX_MESSAGE_TEXT_UTF8_BYTES`.
pub(crate) const MAX_TEXT_BYTES: usize = 400_000;
/// `blockContentLimits.maxBlocks`: every block, nested ones included.
pub(crate) const MAX_BLOCKS: usize = 1_024;
/// `blockContentLimits.maxDepth`: the top level is depth 0.
pub(crate) const MAX_DEPTH: usize = 16;

/// A message's size in the server's terms.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Size {
    pub utf16: usize,
    pub bytes: usize,
    pub blocks: usize,
    /// Deepest nesting level that holds a block.
    pub depth: usize,
}

impl Size {
    pub(crate) fn of(doc: &Doc) -> Self {
        let mut size = Self {
            utf16: doc.text.encode_utf16().count(),
            bytes: doc.text.len(),
            ..Self::default()
        };
        size.walk(&doc.blocks, 0);
        size
    }

    /// Counts as the server's validator does: list items, disclosures,
    /// callouts and quotes nest one level deeper.
    fn walk(&mut self, blocks: &[proto::Block], depth: usize) {
        use proto::block::Kind;
        if !blocks.is_empty() {
            self.depth = self.depth.max(depth);
        }
        for block in blocks {
            self.blocks += 1;
            match &block.kind {
                Some(Kind::List(list)) => {
                    for item in &list.items {
                        self.walk(&item.children, depth + 1);
                    }
                }
                Some(Kind::Disclosure(disclosure)) => self.walk(&disclosure.children, depth + 1),
                Some(Kind::Callout(callout)) => self.walk(&callout.children, depth + 1),
                Some(Kind::Quote(quote)) => self.walk(&quote.children, depth + 1),
                _ => {}
            }
        }
    }

    /// Within the server's limits.
    pub(crate) fn fits(self) -> bool {
        self.within(1, 1)
    }

    /// Within `numerator / denominator` of every limit, leaving room for the
    /// rows that are still growing. Depth always counts in full.
    pub(crate) fn within(self, numerator: usize, denominator: usize) -> bool {
        let share = |limit: usize| limit * numerator / denominator;
        self.utf16 <= share(MAX_TEXT_UTF16)
            && self.bytes <= share(MAX_TEXT_BYTES)
            && self.blocks <= share(MAX_BLOCKS)
            && self.depth <= MAX_DEPTH
    }
}

/// A progress message continues in a new one past 80% of any limit.
pub(crate) fn progress_fits(doc: &Doc) -> bool {
    Size::of(doc).within(4, 5)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::v2::doc::{ActivityKind, DocBuilder, Status};

    fn server_source(path: &str) -> String {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        std::fs::read_to_string(root.join(path)).expect("server source")
    }

    fn constant(source: &str, name: &str) -> usize {
        let line = source
            .lines()
            .find(|line| {
                line.contains(name) && line.contains(':') || line.contains(&format!("{name} ="))
            })
            .unwrap_or_else(|| panic!("{name} not found"));
        let digits: String = line
            .split(['=', ':'])
            .nth(1)
            .expect("value")
            .chars()
            .filter(char::is_ascii_digit)
            .collect();
        digits.parse().expect("number")
    }

    #[test]
    fn limits_match_the_server() {
        let text = server_source("server/src/modules/encryption/limits.ts");
        assert_eq!(
            constant(&text, "MAX_MESSAGE_TEXT_UTF16_UNITS"),
            MAX_TEXT_UTF16
        );
        assert_eq!(
            constant(&text, "MAX_MESSAGE_TEXT_UTF8_BYTES"),
            MAX_TEXT_BYTES
        );
        let blocks = server_source("server/src/modules/message/blockContent.ts");
        assert_eq!(constant(&blocks, "maxBlocks"), MAX_BLOCKS);
        assert_eq!(constant(&blocks, "maxDepth"), MAX_DEPTH);
    }

    #[test]
    fn nested_blocks_count_like_the_server() {
        let mut builder = DocBuilder::new();
        builder.progress("Working", true, |inner| {
            inner.disclosure(
                "Ran cargo test",
                None,
                ActivityKind::Command,
                Status::Done,
                |row| {
                    row.code("$ cargo test", Some("sh"));
                    row.code("ok", None);
                },
            );
        });
        let size = Size::of(&builder.finish());
        // The progress wrapper, the row, and its two code blocks.
        assert_eq!(size.blocks, 4);
        assert_eq!(size.depth, 2);
        assert!(size.fits());
    }

    #[test]
    fn text_over_the_limit_does_not_fit() {
        let doc = Doc::markdown(&"x".repeat(MAX_TEXT_UTF16 + 1));
        assert!(!Size::of(&doc).fits());
        let near = Doc::markdown(&"x".repeat(MAX_TEXT_UTF16 * 4 / 5 + 1));
        assert!(Size::of(&near).fits());
        assert!(!progress_fits(&near));
    }
}
