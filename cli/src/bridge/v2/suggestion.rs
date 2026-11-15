//! Screening for harness prompt suggestions before they reach a composer.
//!
//! Claude Code screens its own; Codex's `thread/sample` returns whatever the
//! model wrote. One screen for both keeps them alike: a short message in the
//! user's voice, or nothing. The rules follow Claude Code's.

use std::sync::LazyLock;

use regex::Regex;

/// Longest suggestion shown, in characters.
const MAX_CHARS: usize = 100;
/// Most words (CJK characters count as half a word).
const MAX_WORDS: usize = 12;

/// One-word answers people really send.
const SINGLE_WORDS: &[&str] = &[
    "yes", "yeah", "yep", "yea", "yup", "sure", "ok", "okay", "push", "commit", "deploy", "stop",
    "continue", "check", "exit", "quit", "no",
];

static WRAPPER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?is)^<(suggestion|response|output|answer|result)>(.*)</(suggestion|response|output|answer|result)>$").unwrap()
});
static LABEL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*(suggested\s+(response|reply|input|prompt|message)|suggestion|response|reply|answer|output|result)\s*[:：]\s*").unwrap()
});
static PREFIXED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\w+:\s").unwrap());
static SENTENCES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[.!?]\s+[A-Z]|[。！？]\s*[\p{L}\p{N}]").unwrap());
static EVALUATIVE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"thanks|thank you|looks good|sounds good|that works|that worked|that's all|\bnice\b|\bgreat\b|perfect|makes sense|awesome|excellent").unwrap()
});
static AGENT_VOICE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(let me|i'll|i've|i'm|i can|i would|i think|i notice|here's|here is|here are|that's|this is|this will|you can|you should|you could|sure,|of course|certainly)").unwrap()
});
static META: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(nothing found\.?|nothing to suggest.*|no suggestion.*|\W*silence\W*)$|\bsilence is\b|\bstay(s|ing)? silent\b").unwrap()
});

/// The suggestion to show, cleaned, or `None` when it should not be shown.
pub(crate) fn screen(raw: &str) -> Option<String> {
    let text = clean(raw);
    let lower = text.to_lowercase();
    let words = word_count(&text);
    let rejected = text.is_empty()
        || lower == "done"
        || META.is_match(&lower)
        || is_wrapped(&text)
        || lower.starts_with("api error:")
        || lower.starts_with("prompt is too long")
        || lower.starts_with("request timed out")
        || PREFIXED.is_match(&text)
        || (words < 2 && !text.starts_with('/') && !SINGLE_WORDS.contains(&lower.as_str()))
        || words > MAX_WORDS
        || text.chars().count() >= MAX_CHARS
        || SENTENCES.is_match(&text)
        || text.contains('\n')
        || text.contains('*')
        || EVALUATIVE.is_match(&lower)
        || AGENT_VOICE.is_match(&text);
    (!rejected).then_some(text)
}

fn clean(raw: &str) -> String {
    let mut text = raw.trim().to_owned();
    if let Some(captures) = WRAPPER.captures(&text)
        && captures[1].eq_ignore_ascii_case(&captures[3])
    {
        text = captures[2].trim().to_owned();
    }
    text = LABEL.replace(&text, "").trim().to_owned();
    for (open, close) in [('"', '"'), ('“', '”'), ('\'', '\''), ('`', '`')] {
        if text.chars().count() >= 2 && text.starts_with(open) && text.ends_with(close) {
            let inner: String = text.chars().skip(1).collect();
            let inner: String = inner.chars().take(inner.chars().count() - 1).collect();
            text = inner.trim().to_owned();
        }
    }
    text
}

fn is_wrapped(text: &str) -> bool {
    [('(', ')'), ('[', ']'), ('（', '）'), ('［', '］'), ('【', '】')]
        .iter()
        .any(|(open, close)| text.starts_with(*open) && text.ends_with(*close))
}

/// Whitespace words; a run of CJK characters counts half a word per character.
fn word_count(text: &str) -> usize {
    let mut halves = 0;
    for word in text.split_whitespace() {
        let cjk = word.chars().filter(|c| is_cjk(*c)).count();
        let other = word.chars().any(|c| c.is_alphanumeric() && !is_cjk(c));
        halves += cjk + if other || cjk == 0 { 2 } else { 0 };
    }
    halves.div_ceil(2)
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
}

#[cfg(test)]
mod tests {
    use super::screen;

    #[test]
    fn keeps_short_messages_in_the_users_voice() {
        assert_eq!(screen("run the tests").as_deref(), Some("run the tests"));
        assert_eq!(screen("  commit this  ").as_deref(), Some("commit this"));
        assert_eq!(screen("yes").as_deref(), Some("yes"));
        assert_eq!(screen("/review").as_deref(), Some("/review"));
        assert_eq!(screen("测试一下").as_deref(), Some("测试一下"));
    }

    #[test]
    fn strips_wrappers_labels_and_quotes() {
        assert_eq!(screen("<suggestion>try it out</suggestion>").as_deref(), Some("try it out"));
        assert_eq!(screen("Suggestion: push it").as_deref(), Some("push it"));
        assert_eq!(screen("\"go ahead\"").as_deref(), Some("go ahead"));
    }

    #[test]
    fn rejects_what_the_user_would_not_type() {
        for text in [
            "",
            "done",
            "nothing to suggest",
            "(silence)",
            "[no suggestion]",
            "hmm",
            "Looks good to me",
            "thanks, that works",
            "Let me run the tests",
            "I'll commit this now",
            "Run the tests. Then commit.",
            "**run** the tests",
            "run the tests\nand commit",
            "Note: run the tests",
            "please go ahead and run the whole test suite then commit and push everything",
            "API Error: overloaded",
        ] {
            assert_eq!(screen(text), None, "{text:?}");
        }
    }
}
