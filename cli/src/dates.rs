//! Relative time parsing for CLI date flags.
//!
//! Supports human-friendly expressions like "2h ago", "yesterday", "monday".

use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Utc, Weekday};
use regex::Regex;
use std::sync::LazyLock;

/// Matches: "2h ago", "30m ago", "1d ago", "2w ago", "1mo ago"
static RELATIVE_AGO_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d+)(mo|w|d|h|m)\s*ago$").expect("valid ago regex"));

/// Matches: "30m", "2h", "1d" (future, for reminders)
static RELATIVE_FUTURE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d+)(mo|w|d|h|m)$").expect("valid future regex"));

/// Parse human-friendly time expressions into Unix timestamps.
///
/// # Supported formats
/// - Relative past: "2h ago", "1d ago", "2w ago", "1mo ago"
/// - Relative future: "30m", "2h", "1d"
/// - Named: "yesterday", "today", "tomorrow"
/// - Weekdays: "monday", "next friday", "this tuesday"
/// - Date: "2024-01-15" (YYYY-MM-DD)
/// - RFC3339: "2024-01-15T10:00:00Z"
///
/// # Arguments
/// * `input` - The time expression to parse
/// * `now` - Reference time (usually current time in UTC)
///
/// # Returns
/// Unix timestamp (seconds since epoch) or error message
pub fn parse_relative_time(input: &str, now: DateTime<Utc>) -> Result<i64, String> {
    let raw = input.trim();
    if raw.is_empty() {
        return Err("empty time expression".to_string());
    }

    let lower = raw.to_lowercase();

    // Named expressions
    match lower.as_str() {
        "yesterday" => return Ok(start_of_day(now - Duration::days(1)).timestamp()),
        "today" => return Ok(start_of_day(now).timestamp()),
        "tomorrow" => return Ok(start_of_day(now + Duration::days(1)).timestamp()),
        _ => {}
    }

    // Weekday expressions
    if let Some(ts) = parse_weekday(&lower, now) {
        return Ok(ts);
    }

    // Relative past: "2h ago", "1d ago"
    if let Some(caps) = RELATIVE_AGO_RE.captures(&lower) {
        let value: i64 = caps[1]
            .parse()
            .map_err(|_| format!("invalid number in {raw:?}"))?;
        if value < 1 {
            return Err(format!("invalid relative time {raw:?}"));
        }
        return apply_relative(now, value, &caps[2], -1);
    }

    // Relative future: "30m", "2h"
    if let Some(caps) = RELATIVE_FUTURE_RE.captures(&lower) {
        let value: i64 = caps[1]
            .parse()
            .map_err(|_| format!("invalid number in {raw:?}"))?;
        if value < 1 {
            return Err(format!("invalid relative time {raw:?}"));
        }
        return apply_relative(now, value, &caps[2], 1);
    }

    // Date: YYYY-MM-DD
    if let Ok(date) = NaiveDate::parse_from_str(raw, "%Y-%m-%d") {
        let dt = date
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| format!("invalid date {raw:?}"))?;
        return Ok(Utc.from_utc_datetime(&dt).timestamp());
    }

    // RFC3339
    if let Ok(dt) = DateTime::parse_from_rfc3339(raw) {
        return Ok(dt.timestamp());
    }

    Err(format!("invalid time expression {raw:?}"))
}

fn start_of_day(dt: DateTime<Utc>) -> DateTime<Utc> {
    dt.date_naive()
        .and_hms_opt(0, 0, 0)
        .map(|naive| Utc.from_utc_datetime(&naive))
        .unwrap_or(dt)
}

fn parse_weekday(input: &str, now: DateTime<Utc>) -> Option<i64> {
    let mut s = input.trim();
    if s.is_empty() {
        return None;
    }

    let next = if let Some(rest) = s.strip_prefix("next ") {
        s = rest.trim();
        true
    } else if let Some(rest) = s.strip_prefix("this ") {
        s = rest.trim();
        false
    } else {
        false
    };

    let target_weekday = match s {
        "sun" | "sunday" => Weekday::Sun,
        "mon" | "monday" => Weekday::Mon,
        "tue" | "tues" | "tuesday" => Weekday::Tue,
        "wed" | "weds" | "wednesday" => Weekday::Wed,
        "thu" | "thur" | "thurs" | "thursday" => Weekday::Thu,
        "fri" | "friday" => Weekday::Fri,
        "sat" | "saturday" => Weekday::Sat,
        _ => return None,
    };

    let base = start_of_day(now);
    let current_weekday = base.weekday();

    let mut delta = (target_weekday.num_days_from_sunday() as i64)
        - (current_weekday.num_days_from_sunday() as i64);
    if delta < 0 {
        delta += 7;
    }
    if next && delta == 0 {
        delta = 7;
    }

    Some((base + Duration::days(delta)).timestamp())
}

fn apply_relative(
    now: DateTime<Utc>,
    value: i64,
    unit: &str,
    direction: i64,
) -> Result<i64, String> {
    let duration = match unit {
        "mo" => {
            // Approximate months as 30 days
            Duration::days(30 * value * direction)
        }
        "w" => Duration::weeks(value * direction),
        "d" => Duration::days(value * direction),
        "h" => Duration::hours(value * direction),
        "m" => Duration::minutes(value * direction),
        _ => return Err(format!("invalid time unit {unit:?}")),
    };
    Ok((now + duration).timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn test_now() -> DateTime<Utc> {
        // Wednesday, January 28, 2026, 15:04:05 UTC
        Utc.with_ymd_and_hms(2026, 1, 28, 15, 4, 5)
            .single()
            .expect("valid datetime")
    }

    fn utc_ts(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
        Utc.with_ymd_and_hms(year, month, day, hour, minute, second)
            .single()
            .expect("valid datetime")
            .timestamp()
    }

    #[test]
    fn test_named_expressions() {
        let now = test_now();

        // yesterday = 2026-01-27 00:00:00 UTC
        let yesterday = parse_relative_time("yesterday", now).expect("yesterday");
        assert_eq!(yesterday, utc_ts(2026, 1, 27, 0, 0, 0));

        // today = 2026-01-28 00:00:00 UTC
        let today = parse_relative_time("today", now).expect("today");
        assert_eq!(today, utc_ts(2026, 1, 28, 0, 0, 0));

        // tomorrow = 2026-01-29 00:00:00 UTC
        let tomorrow = parse_relative_time("tomorrow", now).expect("tomorrow");
        assert_eq!(tomorrow, utc_ts(2026, 1, 29, 0, 0, 0));
    }

    #[test]
    fn test_relative_past() {
        let now = test_now();

        let two_hours_ago = parse_relative_time("2h ago", now).expect("2h ago");
        assert_eq!(two_hours_ago, (now - Duration::hours(2)).timestamp());

        let one_day_ago = parse_relative_time("1d ago", now).expect("1d ago");
        assert_eq!(one_day_ago, (now - Duration::days(1)).timestamp());

        let two_weeks_ago = parse_relative_time("2w ago", now).expect("2w ago");
        assert_eq!(two_weeks_ago, (now - Duration::weeks(2)).timestamp());
    }

    #[test]
    fn test_relative_future() {
        let now = test_now();

        let thirty_mins = parse_relative_time("30m", now).expect("30m");
        assert_eq!(thirty_mins, (now + Duration::minutes(30)).timestamp());

        let two_hours = parse_relative_time("2h", now).expect("2h");
        assert_eq!(two_hours, (now + Duration::hours(2)).timestamp());
    }

    #[test]
    fn test_weekday() {
        let now = test_now(); // Wednesday

        // Monday (next occurrence, since today is Wednesday)
        let monday = parse_relative_time("monday", now).expect("monday");
        assert_eq!(monday, utc_ts(2026, 2, 2, 0, 0, 0));

        // next friday
        let friday = parse_relative_time("next friday", now).expect("next friday");
        assert_eq!(friday, utc_ts(2026, 1, 30, 0, 0, 0));
    }

    #[test]
    fn test_date_formats() {
        let now = test_now();

        // YYYY-MM-DD
        let date = parse_relative_time("2026-01-27", now).expect("date");
        assert_eq!(date, utc_ts(2026, 1, 27, 0, 0, 0));

        // RFC3339
        let rfc = parse_relative_time("2026-01-27T10:00:00Z", now).expect("rfc3339");
        assert_eq!(rfc, utc_ts(2026, 1, 27, 10, 0, 0));
    }

    #[test]
    fn test_invalid_input() {
        let now = test_now();
        assert!(parse_relative_time("not-a-date", now).is_err());
        assert!(parse_relative_time("", now).is_err());
        assert!(parse_relative_time("0h ago", now).is_err());
    }

    #[test]
    fn test_case_insensitive() {
        let now = test_now();
        assert!(parse_relative_time("YESTERDAY", now).is_ok());
        assert!(parse_relative_time("Yesterday", now).is_ok());
        assert!(parse_relative_time("2H AGO", now).is_ok());
    }
}
