use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyAlias {
    pub alias: &'static str,
    pub canonical: &'static str,
}

// Centralized alias table for query/path contexts only.
// Alias keys are lowercase and collision-free.
pub const KEY_ALIASES: &[KeyAlias] = &[
    KeyAlias {
        alias: "au",
        canonical: "auth",
    },
    KeyAlias {
        alias: "at",
        canonical: "attachments",
    },
    KeyAlias {
        alias: "c",
        canonical: "chats",
    },
    KeyAlias {
        alias: "cfg",
        canonical: "config",
    },
    KeyAlias {
        alias: "cid",
        canonical: "chat_id",
    },
    KeyAlias {
        alias: "d",
        canonical: "dialogs",
    },
    KeyAlias {
        alias: "dn",
        canonical: "display_name",
    },
    KeyAlias {
        alias: "em",
        canonical: "email",
    },
    KeyAlias {
        alias: "fid",
        canonical: "from_id",
    },
    KeyAlias {
        alias: "fn",
        canonical: "first_name",
    },
    KeyAlias {
        alias: "it",
        canonical: "items",
    },
    KeyAlias {
        alias: "lm",
        canonical: "last_message",
    },
    KeyAlias {
        alias: "lmd",
        canonical: "last_message_relative_date",
    },
    KeyAlias {
        alias: "lml",
        canonical: "last_message_line",
    },
    KeyAlias {
        alias: "ln",
        canonical: "last_name",
    },
    KeyAlias {
        alias: "m",
        canonical: "message",
    },
    KeyAlias {
        alias: "mb",
        canonical: "member",
    },
    KeyAlias {
        alias: "mbs",
        canonical: "members",
    },
    KeyAlias {
        alias: "md",
        canonical: "media",
    },
    KeyAlias {
        alias: "mid",
        canonical: "message_id",
    },
    KeyAlias {
        alias: "ms",
        canonical: "messages",
    },
    KeyAlias {
        alias: "par",
        canonical: "participant",
    },
    KeyAlias {
        alias: "ph",
        canonical: "phone_number",
    },
    KeyAlias {
        alias: "pth",
        canonical: "paths",
    },
    KeyAlias {
        alias: "pid",
        canonical: "peer_id",
    },
    KeyAlias {
        alias: "ps",
        canonical: "participants",
    },
    KeyAlias {
        alias: "pt",
        canonical: "peer_type",
    },
    KeyAlias {
        alias: "rd",
        canonical: "relative_date",
    },
    KeyAlias {
        alias: "rmi",
        canonical: "read_max_id",
    },
    KeyAlias {
        alias: "s",
        canonical: "spaces",
    },
    KeyAlias {
        alias: "sid",
        canonical: "space_id",
    },
    KeyAlias {
        alias: "sn",
        canonical: "sender_name",
    },
    KeyAlias {
        alias: "sys",
        canonical: "system",
    },
    KeyAlias {
        alias: "ti",
        canonical: "title",
    },
    KeyAlias {
        alias: "u",
        canonical: "users",
    },
    KeyAlias {
        alias: "uc",
        canonical: "unread_count",
    },
    KeyAlias {
        alias: "uid",
        canonical: "user_id",
    },
    KeyAlias {
        alias: "um",
        canonical: "unread_mark",
    },
    KeyAlias {
        alias: "un",
        canonical: "username",
    },
];

static ALIAS_MAP: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| {
    KEY_ALIASES
        .iter()
        .map(|entry| (entry.alias, entry.canonical))
        .collect()
});

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueryContext {
    Jq,
    QueryPath,
    FieldProjection,
    JsonPath,
    SortPath,
}

#[derive(Clone, Debug, Default)]
pub struct JsonQueryOptions {
    pub jq_filter: Option<String>,
    pub query_paths: Vec<String>,
    pub fields: Vec<String>,
    pub jsonpaths: Vec<String>,
    pub sort_path: Option<String>,
    pub sort_desc: bool,
}

impl JsonQueryOptions {
    pub fn has_transforms(&self) -> bool {
        self.jq_filter.is_some()
            || !self.query_paths.is_empty()
            || !self.fields.is_empty()
            || !self.jsonpaths.is_empty()
            || self.sort_path.is_some()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum PathSegment {
    Key(String),
    Index(usize),
    Wildcard,
}

pub fn normalize_aliases(input: &str, context: QueryContext) -> String {
    match context {
        QueryContext::Jq => normalize_expression(input, false),
        QueryContext::JsonPath => normalize_expression(input, true),
        QueryContext::QueryPath | QueryContext::FieldProjection | QueryContext::SortPath => {
            normalize_path(input)
        }
    }
}

pub fn apply_json_transforms(
    mut value: Value,
    options: &JsonQueryOptions,
) -> Result<Value, String> {
    if !options.query_paths.is_empty() {
        let normalized = options
            .query_paths
            .iter()
            .map(|path| normalize_aliases(path, QueryContext::QueryPath))
            .collect::<Vec<_>>();
        value = apply_query_paths(&value, &normalized)?;
    }

    if !options.jsonpaths.is_empty() {
        let normalized = options
            .jsonpaths
            .iter()
            .map(|path| normalize_aliases(path, QueryContext::JsonPath))
            .collect::<Vec<_>>();
        value = apply_jsonpaths(&value, &normalized)?;
    }

    if let Some(path) = &options.sort_path {
        let normalized = normalize_aliases(path, QueryContext::SortPath);
        sort_array_by_path(&mut value, &normalized, options.sort_desc)?;
    }

    if !options.fields.is_empty() {
        let normalized = options
            .fields
            .iter()
            .map(|path| normalize_aliases(path, QueryContext::FieldProjection))
            .collect::<Vec<_>>();
        value = project_fields(value, &normalized)?;
    }

    if let Some(filter) = &options.jq_filter {
        let normalized = normalize_aliases(filter, QueryContext::Jq);
        value = apply_jq_filter(&value, &normalized)?;
    }

    Ok(value)
}

fn normalize_expression(input: &str, rewrite_root_tokens: bool) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;

    let mut in_single = false;
    let mut in_double = false;
    let mut in_comment = false;
    let mut root_ok = rewrite_root_tokens;

    while i < bytes.len() {
        let ch = bytes[i] as char;

        if in_comment {
            out.push(ch);
            i += 1;
            if ch == '\n' {
                in_comment = false;
                root_ok = rewrite_root_tokens;
            }
            continue;
        }

        if in_single {
            out.push(ch);
            i += 1;
            if ch == '\\' && i < bytes.len() {
                out.push(bytes[i] as char);
                i += 1;
                continue;
            }
            if ch == '\'' {
                in_single = false;
            }
            continue;
        }

        if in_double {
            out.push(ch);
            i += 1;
            if ch == '\\' && i < bytes.len() {
                out.push(bytes[i] as char);
                i += 1;
                continue;
            }
            if ch == '"' {
                in_double = false;
            }
            continue;
        }

        match ch {
            '#' => {
                in_comment = true;
                out.push(ch);
                i += 1;
            }
            '\'' => {
                in_single = true;
                out.push(ch);
                i += 1;
            }
            '"' => {
                in_double = true;
                out.push(ch);
                i += 1;
            }
            '.' => {
                out.push(ch);
                i += 1;
                if i < bytes.len() && is_ident_start(bytes[i]) {
                    let start = i;
                    i = read_identifier_end(bytes, i);
                    let token = &input[start..i];
                    out.push_str(rewrite_token(token));
                }
                root_ok = rewrite_root_tokens;
            }
            '$' => {
                out.push(ch);
                i += 1;
                root_ok = rewrite_root_tokens;
            }
            _ if rewrite_root_tokens && root_ok && is_ident_start(bytes[i]) => {
                let start = i;
                i = read_identifier_end(bytes, i);
                let token = &input[start..i];
                out.push_str(rewrite_token(token));
                root_ok = false;
            }
            _ => {
                out.push(ch);
                i += 1;
                root_ok = rewrite_root_tokens && is_root_separator(ch);
            }
        }
    }

    out
}

fn normalize_path(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let mut root_ok = true;

    while i < bytes.len() {
        let ch = bytes[i] as char;
        match ch {
            '$' => {
                out.push(ch);
                i += 1;
                root_ok = true;
            }
            '.' => {
                out.push(ch);
                i += 1;
                root_ok = true;
                if i < bytes.len() && is_ident_start(bytes[i]) {
                    let start = i;
                    i = read_identifier_end(bytes, i);
                    let token = &input[start..i];
                    out.push_str(rewrite_token(token));
                    root_ok = false;
                }
            }
            '[' => {
                i = rewrite_bracket_content(input, bytes, i, &mut out);
                root_ok = false;
            }
            _ if root_ok && is_ident_start(bytes[i]) => {
                let start = i;
                i = read_identifier_end(bytes, i);
                let token = &input[start..i];
                out.push_str(rewrite_token(token));
                root_ok = false;
            }
            _ => {
                out.push(ch);
                i += 1;
                root_ok = ch.is_whitespace() || ch == '|' || ch == ',';
            }
        }
    }

    out
}

fn rewrite_bracket_content(input: &str, bytes: &[u8], mut i: usize, out: &mut String) -> usize {
    out.push('[');
    i += 1;

    if i >= bytes.len() {
        return i;
    }

    let first = bytes[i] as char;
    if first == '\'' || first == '"' {
        let quote = first;
        out.push(quote);
        i += 1;
        while i < bytes.len() {
            let ch = bytes[i] as char;
            out.push(ch);
            i += 1;
            if ch == '\\' && i < bytes.len() {
                out.push(bytes[i] as char);
                i += 1;
                continue;
            }
            if ch == quote {
                break;
            }
        }
        if i < bytes.len() && bytes[i] as char == ']' {
            out.push(']');
            i += 1;
        }
        return i;
    }

    let start = i;
    while i < bytes.len() && bytes[i] as char != ']' {
        i += 1;
    }
    let raw = &input[start..i];
    let rewritten = rewrite_bracket_token(raw);
    out.push_str(&rewritten);

    if i < bytes.len() && bytes[i] as char == ']' {
        out.push(']');
        i += 1;
    }

    i
}

fn rewrite_bracket_token(raw: &str) -> String {
    let leading = raw.len() - raw.trim_start().len();
    let trailing = raw.len() - raw.trim_end().len();
    let core_end = raw.len().saturating_sub(trailing);
    let core = &raw[leading..core_end];

    let rewritten_core = if core.is_empty()
        || core == "*"
        || core.chars().all(|ch| ch.is_ascii_digit())
        || !is_identifier_token(core)
    {
        core.to_string()
    } else {
        rewrite_token(core).to_string()
    };

    format!("{}{}{}", &raw[..leading], rewritten_core, &raw[core_end..])
}

fn rewrite_token(token: &str) -> &str {
    if !is_rewrite_candidate(token) {
        return token;
    }
    ALIAS_MAP.get(token).copied().unwrap_or(token)
}

fn is_rewrite_candidate(token: &str) -> bool {
    !token.is_empty()
        && token
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn is_ident_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_'
}

fn is_ident_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn is_identifier_token(token: &str) -> bool {
    let bytes = token.as_bytes();
    if bytes.is_empty() {
        return false;
    }
    if !is_ident_start(bytes[0]) {
        return false;
    }
    bytes[1..].iter().all(|byte| is_ident_char(*byte))
}

fn read_identifier_end(bytes: &[u8], mut idx: usize) -> usize {
    while idx < bytes.len() && is_ident_char(bytes[idx]) {
        idx += 1;
    }
    idx
}

fn is_root_separator(ch: char) -> bool {
    ch.is_whitespace() || matches!(ch, '|' | ',' | ';' | '(' | ')' | '{' | '}' | '[')
}

fn apply_query_paths(value: &Value, paths: &[String]) -> Result<Value, String> {
    if paths.len() == 1 {
        return select_path_value(value, &paths[0]);
    }

    let mut out = Map::new();
    for path in paths {
        out.insert(path.clone(), select_path_value(value, path)?);
    }
    Ok(Value::Object(out))
}

fn apply_jsonpaths(value: &Value, paths: &[String]) -> Result<Value, String> {
    let mut all = Vec::new();
    for path in paths {
        let values = select_path_values(value, path)?;
        all.extend(values);
    }
    Ok(Value::Array(all))
}

fn select_path_value(value: &Value, path: &str) -> Result<Value, String> {
    let matches = select_path_values(value, path)?;
    Ok(match matches.len() {
        0 => Value::Null,
        1 => matches.into_iter().next().unwrap_or(Value::Null),
        _ => Value::Array(matches),
    })
}

fn select_path_values(value: &Value, path: &str) -> Result<Vec<Value>, String> {
    let segments = parse_path(path)?;
    let mut current = vec![value.clone()];

    for segment in segments {
        let mut next = Vec::new();
        for item in current {
            match segment {
                PathSegment::Key(ref key) => {
                    if let Value::Object(object) = &item
                        && let Some(found) = object.get(key)
                    {
                        next.push(found.clone());
                    }
                }
                PathSegment::Index(idx) => {
                    if let Value::Array(array) = &item
                        && let Some(found) = array.get(idx)
                    {
                        next.push(found.clone());
                    }
                }
                PathSegment::Wildcard => match &item {
                    Value::Array(array) => {
                        next.extend(array.iter().cloned());
                    }
                    Value::Object(object) => {
                        next.extend(object.values().cloned());
                    }
                    _ => {}
                },
            }
        }
        current = next;
        if current.is_empty() {
            break;
        }
    }

    Ok(current)
}

fn parse_path(path: &str) -> Result<Vec<PathSegment>, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("path cannot be empty".to_string());
    }

    let chars: Vec<char> = trimmed.chars().collect();
    let mut idx = 0;
    let mut segments = Vec::new();

    if chars.get(idx) == Some(&'$') {
        idx += 1;
    }

    while idx < chars.len() {
        match chars[idx] {
            '.' => {
                idx += 1;
            }
            '[' => {
                let (segment, next) = parse_bracket_segment(&chars, idx)?;
                segments.push(segment);
                idx = next;
            }
            ch if is_ident_start(ch as u8) => {
                let start = idx;
                idx += 1;
                while idx < chars.len() && is_ident_char(chars[idx] as u8) {
                    idx += 1;
                }
                let key: String = chars[start..idx].iter().collect();
                segments.push(PathSegment::Key(key));
            }
            ch if ch.is_whitespace() => {
                idx += 1;
            }
            ch => {
                return Err(format!("unsupported token '{ch}' in path '{trimmed}'"));
            }
        }
    }

    Ok(segments)
}

fn parse_bracket_segment(chars: &[char], start: usize) -> Result<(PathSegment, usize), String> {
    let mut idx = start + 1;
    while idx < chars.len() && chars[idx].is_whitespace() {
        idx += 1;
    }

    if idx >= chars.len() {
        return Err("unterminated bracket segment".to_string());
    }

    if chars[idx] == '\'' || chars[idx] == '"' {
        let quote = chars[idx];
        idx += 1;
        let value_start = idx;
        while idx < chars.len() {
            if chars[idx] == '\\' {
                idx += 2;
                continue;
            }
            if chars[idx] == quote {
                break;
            }
            idx += 1;
        }
        if idx >= chars.len() || chars[idx] != quote {
            return Err("unterminated quoted key in bracket segment".to_string());
        }
        let key: String = chars[value_start..idx].iter().collect();
        idx += 1;
        while idx < chars.len() && chars[idx].is_whitespace() {
            idx += 1;
        }
        if idx >= chars.len() || chars[idx] != ']' {
            return Err("missing closing ] for bracket segment".to_string());
        }
        return Ok((PathSegment::Key(key), idx + 1));
    }

    let value_start = idx;
    while idx < chars.len() && chars[idx] != ']' {
        idx += 1;
    }
    if idx >= chars.len() {
        return Err("unterminated bracket segment".to_string());
    }
    let raw: String = chars[value_start..idx].iter().collect();
    let token = raw.trim();
    let segment = if token.is_empty() || token == "*" {
        PathSegment::Wildcard
    } else if token.chars().all(|ch| ch.is_ascii_digit()) {
        let parsed = token
            .parse::<usize>()
            .map_err(|_| format!("invalid index '{token}'"))?;
        PathSegment::Index(parsed)
    } else if is_identifier_token(token) {
        PathSegment::Key(token.to_string())
    } else {
        return Err(format!(
            "unsupported bracket expression '{token}' (use dot paths, indexes, *, or quoted keys)"
        ));
    };

    Ok((segment, idx + 1))
}

fn sort_array_by_path(value: &mut Value, path: &str, descending: bool) -> Result<(), String> {
    let segments = parse_path(path)?;
    let Value::Array(items) = value else {
        return Err("--sort-path requires the current JSON value to be an array".to_string());
    };

    items.sort_by(|left, right| compare_path_values(left, right, &segments));
    if descending {
        items.reverse();
    }
    Ok(())
}

fn compare_path_values(left: &Value, right: &Value, segments: &[PathSegment]) -> Ordering {
    let left_value = first_match(left, segments);
    let right_value = first_match(right, segments);
    compare_optional_values(left_value, right_value)
}

fn first_match<'a>(value: &'a Value, segments: &[PathSegment]) -> Option<&'a Value> {
    let mut current = value;
    for segment in segments {
        match segment {
            PathSegment::Key(key) => {
                let Value::Object(object) = current else {
                    return None;
                };
                current = object.get(key)?;
            }
            PathSegment::Index(idx) => {
                let Value::Array(array) = current else {
                    return None;
                };
                current = array.get(*idx)?;
            }
            PathSegment::Wildcard => {
                return None;
            }
        }
    }
    Some(current)
}

fn compare_optional_values(left: Option<&Value>, right: Option<&Value>) -> Ordering {
    match (left, right) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(left), Some(right)) => compare_values(left, right),
    }
}

fn compare_values(left: &Value, right: &Value) -> Ordering {
    match (left, right) {
        (Value::Number(left), Value::Number(right)) => compare_numbers(left, right),
        (Value::String(left), Value::String(right)) => left.cmp(right),
        (Value::Bool(left), Value::Bool(right)) => left.cmp(right),
        (Value::Null, Value::Null) => Ordering::Equal,
        _ => {
            let left_rank = value_rank(left);
            let right_rank = value_rank(right);
            left_rank
                .cmp(&right_rank)
                .then_with(|| left.to_string().cmp(&right.to_string()))
        }
    }
}

fn compare_numbers(left: &serde_json::Number, right: &serde_json::Number) -> Ordering {
    let left_f = left.as_f64().unwrap_or_default();
    let right_f = right.as_f64().unwrap_or_default();
    left_f.partial_cmp(&right_f).unwrap_or(Ordering::Equal)
}

fn value_rank(value: &Value) -> usize {
    match value {
        Value::Null => 0,
        Value::Bool(_) => 1,
        Value::Number(_) => 2,
        Value::String(_) => 3,
        Value::Array(_) => 4,
        Value::Object(_) => 5,
    }
}

fn project_fields(value: Value, fields: &[String]) -> Result<Value, String> {
    let Value::Array(items) = value else {
        return Err("--field requires the current JSON value to be an array".to_string());
    };

    let mut projected = Vec::with_capacity(items.len());
    let parsed_fields = fields
        .iter()
        .map(|path| {
            let segments = parse_path(path)?;
            let label = projection_label(path, &segments);
            Ok((label, segments))
        })
        .collect::<Result<Vec<_>, String>>()?;

    for item in items {
        let mut object = Map::new();
        for (label, segments) in &parsed_fields {
            let value = first_match(&item, segments).cloned().unwrap_or(Value::Null);
            object.insert(label.clone(), value);
        }
        projected.push(Value::Object(object));
    }

    Ok(Value::Array(projected))
}

fn projection_label(path: &str, segments: &[PathSegment]) -> String {
    for segment in segments.iter().rev() {
        if let PathSegment::Key(key) = segment {
            return key.clone();
        }
    }
    path.to_string()
}

fn apply_jq_filter(value: &Value, filter: &str) -> Result<Value, String> {
    let mut child = Command::new("jq")
        .arg("-c")
        .arg(filter)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("failed to run jq: {error}"))?;

    let payload =
        serde_json::to_vec(value).map_err(|error| format!("failed to encode json: {error}"))?;
    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| "failed to open jq stdin".to_string())?;
        stdin
            .write_all(&payload)
            .map_err(|error| format!("failed to write jq stdin: {error}"))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|error| format!("failed to wait for jq: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let message = stderr.trim();
        return Err(if message.is_empty() {
            "jq filter failed".to_string()
        } else {
            format!("jq filter failed: {message}")
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines = stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();

    if lines.is_empty() {
        return Ok(Value::Null);
    }

    if lines.len() == 1 {
        return serde_json::from_str(lines[0])
            .map_err(|error| format!("invalid jq output: {error}"));
    }

    let mut values = Vec::with_capacity(lines.len());
    for line in lines {
        let parsed = serde_json::from_str(line)
            .map_err(|error| format!("invalid jq output line: {error}"))?;
        values.push(parsed);
    }
    Ok(Value::Array(values))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rewrites_aliases_in_jq_field_paths() {
        let input = ".u[] | .fn + \" \" + (.ln // \"\")";
        let output = normalize_aliases(input, QueryContext::Jq);
        assert_eq!(
            output,
            ".users[] | .first_name + \" \" + (.last_name // \"\")"
        );
    }

    #[test]
    fn does_not_rewrite_strings_comments_or_mixed_case_tokens() {
        let input = ".u[] | .Fn # .fn should stay in comment\n| \".fn\" | .fn";
        let output = normalize_aliases(input, QueryContext::Jq);
        assert_eq!(
            output,
            ".users[] | .Fn # .fn should stay in comment\n| \".fn\" | .first_name"
        );
    }

    #[test]
    fn preserves_quoted_bracket_keys() {
        let input = "users[\"fn\"].ln";
        let output = normalize_aliases(input, QueryContext::QueryPath);
        assert_eq!(output, "users[\"fn\"].last_name");
    }

    #[test]
    fn rewrites_root_and_nested_path_segments() {
        let input = "u[].fn";
        let output = normalize_aliases(input, QueryContext::QueryPath);
        assert_eq!(output, "users[].first_name");
    }

    #[test]
    fn keeps_long_form_paths_backward_compatible() {
        let input = "users[].first_name";
        let output = normalize_aliases(input, QueryContext::QueryPath);
        assert_eq!(output, "users[].first_name");
    }

    #[test]
    fn query_paths_extract_values() {
        let value = json!({"users": [{"first_name": "Ada"}]});
        let out = apply_query_paths(&value, &["users[0].first_name".to_string()])
            .expect("query should succeed");
        assert_eq!(out, json!("Ada"));
    }

    #[test]
    fn fields_project_array_objects() {
        let value = json!([
            {"id": 2, "first_name": "Bea", "last_name": "Lee"},
            {"id": 1, "first_name": "Ada", "last_name": "Chen"}
        ]);
        let out = project_fields(value, &["id".to_string(), "first_name".to_string()])
            .expect("projection should succeed");
        assert_eq!(
            out,
            json!([
                {"id": 2, "first_name": "Bea"},
                {"id": 1, "first_name": "Ada"}
            ])
        );
    }

    #[test]
    fn sort_path_orders_array() {
        let mut value = json!([
            {"id": 2, "display_name": "Bea"},
            {"id": 1, "display_name": "Ada"}
        ]);
        sort_array_by_path(&mut value, "display_name", false).expect("sort should succeed");
        assert_eq!(
            value,
            json!([
                {"id": 1, "display_name": "Ada"},
                {"id": 2, "display_name": "Bea"}
            ])
        );
    }

    #[test]
    fn pipeline_uses_aliases_without_mutating_payload_keys() {
        let original = json!({
            "users": [
                {"id": 1, "first_name": "Ada"},
                {"id": 2, "first_name": "Bea"}
            ]
        });
        let options = JsonQueryOptions {
            query_paths: vec!["u".to_string()],
            sort_path: Some("fn".to_string()),
            fields: vec!["id".to_string(), "fn".to_string()],
            ..Default::default()
        };

        let out =
            apply_json_transforms(original.clone(), &options).expect("pipeline should succeed");
        assert_eq!(
            out,
            json!([
                {"id": 1, "first_name": "Ada"},
                {"id": 2, "first_name": "Bea"}
            ])
        );

        assert!(
            original
                .get("users")
                .and_then(|value| value.as_array())
                .and_then(|array| array.first())
                .and_then(|item| item.get("first_name"))
                .is_some()
        );
    }
}
