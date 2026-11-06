//! Offline intent search over the live clap command tree (`inline cli search`).
//!
//! Agents describe a task in words and get a handful of matching commands back
//! instead of walking nested `--help` output. Pattern borrowed from Cloudflare's
//! `cf cli search`: index names, summaries, keywords, and flag help with field
//! weights, then return a compact top-N.

use std::collections::{HashMap, HashSet};

use clap::Command;
use serde::Serialize;

pub(crate) const DEFAULT_LIMIT: u8 = 5;
pub(crate) const MAX_LIMIT: u8 = 20;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchHit {
    pub(crate) command: String,
    pub(crate) summary: String,
}

#[derive(Clone, Copy)]
enum Field {
    Name,
    Parent,
    Summary,
    Keywords,
    Description,
    Context,
}

impl Field {
    const ALL: [Field; 6] = [
        Field::Name,
        Field::Parent,
        Field::Summary,
        Field::Keywords,
        Field::Description,
        Field::Context,
    ];

    fn weight(self) -> f64 {
        match self {
            Field::Name => 8.0,
            Field::Parent => 4.0,
            Field::Summary => 5.0,
            Field::Keywords => 5.0,
            Field::Description => 2.0,
            Field::Context => 0.5,
        }
    }
}

struct Document {
    command: String,
    summary: String,
    depth: usize,
    fields: [Vec<String>; 6],
}

/// Extra words people and agents use for a command, keyed by its canonical
/// path without the leading `inline`. A test keeps every key pointing at a
/// real visible command.
#[rustfmt::skip]
const KEYWORDS: &[(&str, &[&str])] = &[
    ("auth login", &["signin", "sign", "log", "authenticate", "token", "account"]),
    ("auth me", &["whoami", "who", "current", "account", "profile", "identity", "user"]),
    ("auth logout", &["signout", "sign", "log", "out"]),
    ("auth sessions", &["devices", "logged", "active"]),
    ("auth revoke-session", &["logout", "device", "kick", "remove"]),
    ("update", &["upgrade", "latest", "version", "release", "install"]),
    ("doctor", &["diagnose", "debug", "troubleshoot", "health", "problem", "broken", "version"]),
    ("skill install", &["agent", "skill", "codex", "instructions"]),
    ("plugin install", &["mcp", "claude", "codex", "oauth", "integration", "marketplace"]),
    ("setup codex", &["agent", "bot", "openai", "coding", "ai"]),
    ("setup claude", &["agent", "bot", "anthropic", "code", "coding", "ai"]),
    ("setup opencode", &["agent", "bot", "coding", "ai"]),
    ("setup amp", &["agent", "bot", "coding", "ai"]),
    ("agents discover", &["installed", "detect", "find", "harness", "ai"]),
    ("agents setup", &["bot", "install", "configure", "ai"]),
    ("bridge status", &["agent", "health", "running", "daemon", "service"]),
    ("bridge logs", &["agent", "debug", "output", "daemon"]),
    ("bridge workspace add", &["project", "folder", "repo", "directory"]),
    ("bridge operators add", &["allow", "permission", "access", "user"]),
    ("chats list", &["inbox", "unread", "conversations", "threads", "channels", "sidebar", "recent", "dms"]),
    ("chats get", &["info", "details", "show"]),
    ("chats create", &["new", "channel", "group", "start", "open"]),
    ("chats subthread", &["reply", "child", "thread", "branch"]),
    ("chats create-dm", &["direct", "private", "conversation", "person", "dm", "new"]),
    ("chats participants", &["members", "people", "who"]),
    ("chats add-participant", &["invite", "add", "member", "person"]),
    ("chats remove-participant", &["kick", "remove", "member"]),
    ("chats rename", &["title", "name", "change"]),
    ("chats mark-read", &["seen", "clear", "unread", "read"]),
    ("chats mark-unread", &["later", "unread"]),
    ("chats archive", &["hide", "done", "close"]),
    ("chats unarchive", &["restore", "unhide"]),
    ("chats follow", &["subscribe", "watch"]),
    ("chats unfollow", &["unsubscribe", "unwatch", "mute"]),
    ("chats delete", &["remove", "destroy"]),
    ("chats move", &["home", "space", "transfer"]),
    ("chats update-visibility", &["public", "private", "visibility"]),
    ("users list", &["people", "teammates", "members", "directory", "contacts", "find", "lookup"]),
    ("users get", &["profile", "person", "lookup"]),
    ("messages list", &["history", "recent", "read", "latest", "conversation", "fetch", "thread", "replies"]),
    ("messages search", &["find", "grep", "query", "lookup", "keyword"]),
    ("messages get", &["read", "fetch", "show", "id"]),
    ("messages send", &["post", "write", "reply", "say", "attach", "file", "image", "photo", "upload", "mention", "dm", "text", "thread"]),
    ("messages forward", &["share", "resend", "copy"]),
    ("messages export", &["dump", "backup", "json", "jsonl", "csv", "save", "history", "archive"]),
    ("messages transcript", &["markdown", "export", "conversation", "history", "summary", "dump"]),
    ("messages download", &["file", "media", "attachment", "image", "photo", "video", "save"]),
    ("messages delete", &["remove", "unsend", "erase"]),
    ("messages edit", &["change", "fix", "modify", "update", "correct"]),
    ("messages add-reaction", &["react", "emoji", "like"]),
    ("messages delete-reaction", &["unreact", "remove", "emoji"]),
    ("messages pin", &["pinned", "important", "highlight"]),
    ("spaces list", &["workspaces", "teams", "organizations", "orgs"]),
    ("spaces members", &["people", "team", "users"]),
    ("spaces invite", &["add", "join", "teammate", "member", "email"]),
    ("spaces delete-member", &["kick", "remove", "user"]),
    ("spaces update-member-access", &["role", "permission", "admin", "promote"]),
    ("notifications get", &["alerts", "settings", "status"]),
    ("notifications set", &["mute", "unmute", "mentions", "alerts", "sound", "silent"]),
    ("notifications set-chat", &["mute", "unmute", "silence", "snooze", "chat", "dm"]),
    ("notifications get-chat", &["override", "status", "chat", "dm"]),
    ("tasks create-linear", &["issue", "ticket", "bug", "todo"]),
    ("tasks create-notion", &["task", "todo", "page"]),
    ("bots list", &["bot", "integrations"]),
    ("bots create", &["new", "bot", "token", "integration"]),
    ("bots reveal-token", &["api", "key", "secret", "token", "credentials"]),
    ("typing start", &["compose", "indicator", "typing"]),
    ("completion", &["shell", "bash", "zsh", "fish", "autocomplete", "tab"]),
    ("capabilities", &["flags", "options", "schema", "json", "metadata"]),
];

/// Query-side synonyms: a query word also searches for these words, at a
/// lower weight than the word itself.
#[rustfmt::skip]
const SYNONYMS: &[(&str, &[&str])] = &[
    ("thread", &["chat"]),
    ("channel", &["chat", "thread"]),
    ("conversation", &["chat"]),
    ("group", &["chat"]),
    ("room", &["chat"]),
    ("dm", &["chat", "user"]),
    ("direct", &["chat", "dm"]),
    ("pm", &["dm", "chat"]),
    ("person", &["user"]),
    ("people", &["user", "member"]),
    ("teammate", &["user", "member"]),
    ("contact", &["user"]),
    ("colleague", &["user"]),
    ("post", &["send", "message"]),
    ("write", &["send"]),
    ("say", &["send"]),
    ("tell", &["send"]),
    ("reply", &["send"]),
    ("respond", &["send", "reply"]),
    ("edit", &["update"]),
    ("change", &["edit", "update", "set"]),
    ("modify", &["edit", "update"]),
    ("update", &["edit", "set"]),
    ("remove", &["delete"]),
    ("delete", &["remove"]),
    ("unsend", &["delete"]),
    ("erase", &["delete"]),
    ("trash", &["delete"]),
    ("react", &["reaction"]),
    ("emoji", &["reaction"]),
    ("file", &["attach", "media"]),
    ("image", &["attach", "media"]),
    ("photo", &["attach", "media"]),
    ("picture", &["attach", "media"]),
    ("video", &["attach", "media"]),
    ("attachment", &["attach", "media"]),
    ("upload", &["attach"]),
    ("screenshot", &["attach", "image"]),
    ("mute", &["notification"]),
    ("unmute", &["notification"]),
    ("silence", &["notification", "mute"]),
    ("snooze", &["notification", "mute"]),
    ("alert", &["notification"]),
    ("todo", &["task"]),
    ("issue", &["task", "linear"]),
    ("ticket", &["task", "linear"]),
    ("history", &["list", "transcript", "export"]),
    ("dump", &["export"]),
    ("backup", &["export"]),
    ("find", &["search"]),
    ("lookup", &["search", "get"]),
    ("grep", &["search"]),
    ("show", &["get", "list"]),
    ("view", &["get", "list"]),
    ("read", &["get", "list"]),
    ("fetch", &["get", "list"]),
    ("open", &["get"]),
    ("see", &["get", "list"]),
    ("signin", &["login"]),
    ("authenticate", &["login"]),
    ("signout", &["logout"]),
    ("whoami", &["me"]),
    ("profile", &["me", "user"]),
    ("workspace", &["space"]),
    ("team", &["space"]),
    ("org", &["space"]),
    ("organization", &["space"]),
    ("company", &["space"]),
    ("kick", &["remove", "delete"]),
    ("agent", &["bot", "setup"]),
    ("ai", &["agent", "bot"]),
    ("assistant", &["agent", "bot"]),
    ("llm", &["agent"]),
    ("upgrade", &["update"]),
    ("save", &["download", "export"]),
];

#[rustfmt::skip]
const STOPWORDS: &[&str] = &[
    "a", "an", "the", "to", "of", "for", "in", "on", "at", "by", "with", "from", "and", "or",
    "into", "is", "are", "be", "it", "its", "this", "that", "how", "do", "does", "i", "my", "can",
    "some", "inline", "using", "use", "via", "as", "any", "want", "need", "please", "should",
    "would", "will", "what", "which", "about", "help", "cli", "command",
];

const SYNONYM_FACTOR: f64 = 0.8;

pub(crate) fn search(root: &Command, query: &str, limit: usize) -> Vec<SearchHit> {
    let documents = build_index(root);
    rank(&documents, query, limit)
}

fn rank(documents: &[Document], query: &str, limit: usize) -> Vec<SearchHit> {
    let terms = query_terms(query);
    if terms.is_empty() || documents.is_empty() {
        return Vec::new();
    }
    let (idf, rarest) = inverse_document_frequency(documents);

    let mut scored: Vec<(f64, &Document)> = documents
        .iter()
        .filter_map(|document| {
            let mut total = 0.0;
            let mut matched = 0usize;
            for expansions in &terms {
                let best = expansions
                    .iter()
                    .map(|(term, factor)| factor * term_score(document, term, &idf, rarest))
                    .fold(0.0, f64::max);
                if best > 0.0 {
                    matched += 1;
                    total += best;
                }
            }
            (matched > 0).then(|| {
                let coverage = matched as f64 / terms.len() as f64;
                (total * coverage * coverage, document)
            })
        })
        .collect();

    scored.sort_by(|(left_score, left), (right_score, right)| {
        right_score
            .total_cmp(left_score)
            .then(left.depth.cmp(&right.depth))
            .then(left.command.cmp(&right.command))
    });
    scored
        .into_iter()
        .take(limit)
        .map(|(_, document)| SearchHit {
            command: document.command.clone(),
            summary: document.summary.clone(),
        })
        .collect()
}

fn term_score(document: &Document, term: &str, idf: &HashMap<String, f64>, rarest: f64) -> f64 {
    Field::ALL
        .iter()
        .map(|field| {
            let best = document.fields[*field as usize]
                .iter()
                .map(|token| {
                    match_strength(term, token) * idf.get(token).copied().unwrap_or(rarest)
                })
                .fold(0.0, f64::max);
            field.weight() * best
        })
        .fold(0.0, f64::max)
}

fn match_strength(term: &str, token: &str) -> f64 {
    if term == token {
        return 1.0;
    }
    let term_len = term.chars().count();
    let token_len = token.chars().count();
    if term_len >= 3 && token.starts_with(term) {
        return 0.75;
    }
    if term_len >= 5 && token_len >= 5 && within_one_edit(term, token) {
        return 0.5;
    }
    0.0
}

/// Document frequency ignores the context field: every child repeats its
/// parent's about text there, which would make words like "list" look common.
/// Tokens seen only in context fall back to the rarest weight.
fn inverse_document_frequency(documents: &[Document]) -> (HashMap<String, f64>, f64) {
    let mut frequency: HashMap<String, usize> = HashMap::new();
    for document in documents {
        let unique: HashSet<&String> = Field::ALL
            .iter()
            .filter(|field| !matches!(field, Field::Context))
            .flat_map(|field| &document.fields[*field as usize])
            .collect();
        for token in unique {
            *frequency.entry(token.clone()).or_default() += 1;
        }
    }
    let count = documents.len() as f64;
    let idf = frequency
        .into_iter()
        .map(|(token, df)| (token, (1.0 + count / df as f64).ln()))
        .collect();
    (idf, (1.0 + count).ln())
}

/// Each query word becomes a group of (stemmed term, factor) alternatives.
fn query_terms(query: &str) -> Vec<Vec<(String, f64)>> {
    let mut seen = HashSet::new();
    raw_words(query)
        .filter(|word| seen.insert(word.clone()))
        .map(|word| {
            let mut expansions = vec![(stem(&word), 1.0)];
            if let Some((_, synonyms)) = SYNONYMS.iter().find(|(key, _)| *key == word) {
                for synonym in *synonyms {
                    let synonym = stem(synonym);
                    if !expansions.iter().any(|(term, _)| *term == synonym) {
                        expansions.push((synonym, SYNONYM_FACTOR));
                    }
                }
            }
            expansions
        })
        .collect()
}

fn build_index(root: &Command) -> Vec<Document> {
    let mut root = root.clone();
    root.build();
    let mut documents = Vec::new();
    for child in visible_subcommands(&root) {
        collect(child, &[], &[], &mut documents);
    }
    documents
}

fn visible_subcommands(command: &Command) -> impl Iterator<Item = &Command> {
    command
        .get_subcommands()
        .filter(|child| !child.is_hide_set() && child.get_name() != "help")
}

fn collect(
    command: &Command,
    path: &[&Command],
    parent_abouts: &[String],
    out: &mut Vec<Document>,
) {
    let about = command
        .get_about()
        .or_else(|| command.get_long_about())
        .map(ToString::to_string)
        .unwrap_or_default();
    let has_children = visible_subcommands(command).next().is_some();
    let runnable = !has_children || !command.is_subcommand_required_set();
    // Visible shortcuts duplicate a canonical command; rank the canonical one.
    let is_shortcut = about.contains("(shortcut for ");

    if runnable && !is_shortcut && !about.is_empty() {
        out.push(document(command, path, parent_abouts, &about));
    }

    let mut child_path = path.to_vec();
    child_path.push(command);
    let mut child_abouts = parent_abouts.to_vec();
    child_abouts.push(about);
    for child in visible_subcommands(command) {
        collect(child, &child_path, &child_abouts, out);
    }
}

fn document(
    command: &Command,
    path: &[&Command],
    parent_abouts: &[String],
    about: &str,
) -> Document {
    let mut names: Vec<&str> = path.iter().map(|segment| segment.get_name()).collect();
    names.push(command.get_name());
    let key = names.join(" ");

    let mut name_text = command.get_name().to_string();
    for alias in command.get_all_aliases() {
        name_text.push(' ');
        name_text.push_str(alias);
    }
    let mut parent_text = String::new();
    for segment in path {
        parent_text.push(' ');
        parent_text.push_str(segment.get_name());
        for alias in segment.get_all_aliases() {
            parent_text.push(' ');
            parent_text.push_str(alias);
        }
    }

    let keywords = KEYWORDS
        .iter()
        .find(|(path, _)| *path == key)
        .map(|(_, words)| words.join(" "))
        .unwrap_or_default();

    let description = [
        command.get_long_about().map(ToString::to_string),
        command
            .get_after_long_help()
            .or_else(|| command.get_after_help())
            .map(ToString::to_string),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ");

    let mut context = parent_abouts.join(" ");
    for argument in command.get_arguments() {
        if argument.is_hide_set() || argument.is_global_set() {
            continue;
        }
        let id = argument.get_id().as_str();
        if id == "help" || id == "version" {
            continue;
        }
        context.push(' ');
        context.push_str(argument.get_long().unwrap_or(id));
        if let Some(help) = argument.get_help() {
            context.push(' ');
            context.push_str(&help.to_string());
        }
    }

    Document {
        command: format!("inline {key}"),
        summary: about.lines().next().unwrap_or_default().trim().to_string(),
        depth: names.len(),
        fields: [
            tokens(&name_text),
            tokens(&parent_text),
            tokens(about),
            tokens(&keywords),
            tokens(&description),
            tokens(&context),
        ],
    }
}

fn raw_words(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .filter(|word| !word.chars().all(|c| c.is_ascii_digit()))
        .filter(|word| !STOPWORDS.contains(&word.as_str()))
}

fn tokens(text: &str) -> Vec<String> {
    raw_words(text).map(|word| stem(&word)).collect()
}

/// Tiny suffix stripper so "messages", "message", and "messaging" meet. Both
/// sides go through it, so stems only need to be consistent, not real words.
fn stem(word: &str) -> String {
    let mut word = word.to_string();
    let len = |w: &str| w.chars().count();

    if word.ends_with("ies") && len(&word) > 4 {
        word.truncate(word.len() - 3);
        word.push('y');
    } else if ["sses", "ches", "shes", "xes"]
        .iter()
        .any(|suffix| word.ends_with(suffix))
    {
        word.truncate(word.len() - 2);
    } else if word.ends_with('s') && !word.ends_with("ss") && len(&word) > 3 {
        word.pop();
    }

    let mut stripped = false;
    if word.ends_with("ing") && len(&word) > 5 {
        word.truncate(word.len() - 3);
        stripped = true;
    } else if word.ends_with("ed") && len(&word) > 4 {
        word.truncate(word.len() - 2);
        stripped = true;
    }
    if stripped {
        let bytes = word.as_bytes();
        let n = bytes.len();
        if n >= 2 && bytes[n - 1] == bytes[n - 2] && !b"aeiouls".contains(&bytes[n - 1]) {
            word.pop();
        }
    }

    if word.ends_with('e') && len(&word) > 4 {
        word.pop();
    }
    word
}

fn within_one_edit(left: &str, right: &str) -> bool {
    let left: Vec<char> = left.chars().collect();
    let right: Vec<char> = right.chars().collect();
    let (short, long) = if left.len() <= right.len() {
        (&left, &right)
    } else {
        (&right, &left)
    };
    if long.len() - short.len() > 1 {
        return false;
    }
    let mut i = 0;
    let mut j = 0;
    let mut edits = 0;
    while i < short.len() && j < long.len() {
        if short[i] == long[j] {
            i += 1;
            j += 1;
            continue;
        }
        edits += 1;
        if edits > 1 {
            return false;
        }
        if short.len() == long.len() {
            i += 1;
        }
        j += 1;
    }
    edits + (long.len() - j) + (short.len() - i) <= 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn live() -> Vec<Document> {
        build_index(&crate::Cli::command())
    }

    fn top(documents: &[Document], query: &str, n: usize) -> Vec<String> {
        rank(documents, query, n)
            .into_iter()
            .map(|hit| hit.command)
            .collect()
    }

    #[test]
    fn real_tasks_rank_the_expected_command() {
        let documents = live();
        let cases: &[(&str, &str, usize)] = &[
            ("send a file to a thread", "inline messages send", 1),
            ("post a message in a channel", "inline messages send", 1),
            ("reply to a message", "inline messages send", 3),
            ("reply in thread", "inline messages send", 2),
            ("read thread replies", "inline messages list", 1),
            ("who am i", "inline auth me", 1),
            ("log in", "inline auth login", 1),
            ("mute a chat", "inline notifications set-chat", 1),
            (
                "export conversation to markdown",
                "inline messages transcript",
                2,
            ),
            (
                "create a linear issue from a message",
                "inline tasks create-linear",
                1,
            ),
            (
                "react to a message with an emoji",
                "inline messages add-reaction",
                1,
            ),
            ("delete a message", "inline messages delete", 1),
            (
                "forward a message to another chat",
                "inline messages forward",
                1,
            ),
            ("list unread chats", "inline chats list", 1),
            ("set up claude code", "inline setup claude", 1),
            (
                "find messages about the release",
                "inline messages search",
                1,
            ),
            ("download attachments", "inline messages download", 1),
            ("invite someone to my workspace", "inline spaces invite", 1),
            ("start a dm with a person", "inline chats create-dm", 1),
            ("edit a message", "inline messages edit", 1),
            ("rename a thread", "inline chats rename", 1),
            ("upgrade the cli", "inline update", 1),
            ("get a bot token", "inline bots reveal-token", 1),
            ("pin a message", "inline messages pin", 1),
            ("shell completions", "inline completion", 1),
        ];
        let mut failures = Vec::new();
        for (query, expected, within) in cases {
            let results = top(&documents, query, *within);
            if !results.iter().any(|command| command == expected) {
                failures.push(format!(
                    "{query:?}: expected {expected} in top {within}, got {:?}",
                    top(&documents, query, 5)
                ));
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn typos_and_prefixes_still_match() {
        let documents = live();
        assert_eq!(top(&documents, "notif", 1), ["inline notifications get"]);
        assert!(
            top(&documents, "forwrd message", 1).contains(&"inline messages forward".to_string())
        );
    }

    #[test]
    fn hidden_shortcut_and_help_commands_are_not_indexed() {
        let documents = live();
        let commands: HashSet<&str> = documents.iter().map(|d| d.command.as_str()).collect();
        for excluded in [
            "inline bridge run",
            "inline bridge supervise",
            "inline help",
            "inline login",
            "inline search",
            "inline me",
            "inline transcript",
            "inline chats",
            "inline messages",
        ] {
            assert!(
                !commands.contains(excluded),
                "{excluded} should not be indexed"
            );
        }
        assert!(
            commands.contains("inline update"),
            "runnable groups stay searchable"
        );
        assert!(commands.contains("inline cli search"));
    }

    #[test]
    fn keyword_table_points_at_visible_commands() {
        let documents = live();
        let commands: HashSet<&str> = documents.iter().map(|d| d.command.as_str()).collect();
        for (path, _) in KEYWORDS {
            assert!(
                commands.contains(format!("inline {path}").as_str()),
                "KEYWORDS entry {path:?} does not match an indexed command"
            );
        }
    }

    #[test]
    fn empty_or_stopword_queries_return_nothing() {
        let documents = live();
        assert!(rank(&documents, "", 5).is_empty());
        assert!(rank(&documents, "the a to", 5).is_empty());
        assert!(rank(&documents, "zzzqqq", 5).is_empty());
    }

    #[test]
    fn limit_is_respected() {
        let documents = live();
        assert_eq!(rank(&documents, "message", 3).len(), 3);
    }

    #[test]
    fn stemming_is_consistent() {
        assert_eq!(stem("messages"), stem("message"));
        assert_eq!(stem("archived"), stem("archive"));
        assert_eq!(stem("replies"), stem("reply"));
        assert_eq!(stem("pinned"), stem("pin"));
        assert_eq!(stem("sending"), stem("send"));
    }

    #[test]
    fn one_edit_distance() {
        assert!(within_one_edit("forwrd", "forward"));
        assert!(within_one_edit("mesage", "message"));
        assert!(within_one_edit("rename", "renane"));
        assert!(!within_one_edit("rename", "delete"));
    }
}
