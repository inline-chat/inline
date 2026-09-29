use std::collections::HashSet;

use crate::errors::CliError;

const MAX_EXPANDED_MESSAGE_IDS: usize = 1_000;

pub(crate) fn parse_message_id_selectors(
    name: &str,
    selectors: &[String],
) -> Result<Vec<i64>, Box<dyn std::error::Error>> {
    parse_selectors(name, selectors, true)
}

/// Forwarding is an ordered write: repeating an ID deliberately delivers it again.
pub(crate) fn parse_forward_message_id_selectors(
    name: &str,
    selectors: &[String],
) -> Result<Vec<i64>, Box<dyn std::error::Error>> {
    parse_selectors(name, selectors, false)
}

fn parse_selectors(
    name: &str,
    selectors: &[String],
    deduplicate: bool,
) -> Result<Vec<i64>, Box<dyn std::error::Error>> {
    if selectors.is_empty() {
        return Err(CliError::missing_message_ids().into());
    }

    let mut ids = Vec::new();
    let mut seen = HashSet::new();

    for selector in selectors {
        for part in selector.split(',') {
            let part = part.trim();
            if part.is_empty() {
                return Err(invalid_selector(name).into());
            }

            if let Some((start, end)) = part.split_once('-') {
                let start = parse_positive_id(name, start.trim())?;
                let end = parse_positive_id(name, end.trim())?;
                if end < start {
                    return Err(CliError::invalid_args(format!(
                        "{name} range must be ascending: {part}"
                    ))
                    .into());
                }
                for id in start..=end {
                    push_id(name, id, &mut ids, &mut seen, deduplicate)?;
                }
            } else {
                let id = parse_positive_id(name, part)?;
                push_id(name, id, &mut ids, &mut seen, deduplicate)?;
            }
        }
    }

    if ids.is_empty() {
        return Err(CliError::missing_message_ids().into());
    }

    Ok(ids)
}

fn parse_positive_id(name: &str, value: &str) -> Result<i64, CliError> {
    let id = value.parse::<i64>().map_err(|_| invalid_selector(name))?;
    if id <= 0 {
        return Err(CliError::invalid_args(format!(
            "{name} values must be positive message IDs"
        )));
    }
    Ok(id)
}

fn push_id(
    name: &str,
    id: i64,
    ids: &mut Vec<i64>,
    seen: &mut HashSet<i64>,
    deduplicate: bool,
) -> Result<(), CliError> {
    if !deduplicate || seen.insert(id) {
        ids.push(id);
        if ids.len() > MAX_EXPANDED_MESSAGE_IDS {
            return Err(CliError::invalid_args(format!(
                "{name} selectors expand to more than {MAX_EXPANDED_MESSAGE_IDS} messages"
            )));
        }
    }
    Ok(())
}

fn invalid_selector(name: &str) -> CliError {
    CliError::invalid_args(format!(
        "{name} must be a message id selector like 91, 91,92,100, or 91-100"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(values: &[&str]) -> Result<Vec<i64>, Box<dyn std::error::Error>> {
        parse_message_id_selectors(
            "--message-id",
            &values
                .iter()
                .map(|value| value.to_string())
                .collect::<Vec<_>>(),
        )
    }

    #[test]
    fn forward_selectors_preserve_each_occurrence_and_bound_expansion() {
        let selectors = vec!["9,3,9".into(), "7-9".into()];
        assert_eq!(
            parse_forward_message_id_selectors("--message-id", &selectors).unwrap(),
            [9, 3, 9, 7, 8, 9]
        );
        assert_eq!(
            parse_message_id_selectors("--message-id", &selectors).unwrap(),
            [9, 3, 7, 8]
        );
        assert!(parse_forward_message_id_selectors("--message-id", &["1-1001".into()]).is_err());
        assert!(parse_forward_message_id_selectors("--message-id", &["9-3".into()]).is_err());
    }

    #[test]
    fn parses_single_ids_lists_ranges_and_repeated_flags() {
        assert_eq!(parse(&["91"]).unwrap(), vec![91]);
        assert_eq!(parse(&["91,92,100"]).unwrap(), vec![91, 92, 100]);
        assert_eq!(parse(&["91-94"]).unwrap(), vec![91, 92, 93, 94]);
        assert_eq!(
            parse(&["3,7", "7-10", "13"]).unwrap(),
            vec![3, 7, 8, 9, 10, 13]
        );
    }

    #[test]
    fn rejects_invalid_selectors() {
        assert!(parse(&[]).is_err());
        assert!(parse(&[""]).is_err());
        assert!(parse(&["0"]).is_err());
        assert!(parse(&["-1"]).is_err());
        assert!(parse(&["100-91"]).is_err());
        assert!(parse(&["1-1001"]).is_err());
        assert!(parse(&["1,,2"]).is_err());
    }
}
