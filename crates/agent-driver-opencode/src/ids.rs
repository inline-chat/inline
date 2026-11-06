//! OpenCode identifiers.
//!
//! OpenCode message ids start with `msg_` and are time-ordered: the first 12
//! hex characters encode `timestamp_ms * 0x1000 + counter`, followed by 14
//! base62 characters (`@opencode/schema` `Identifier.ascending`). Inline
//! creates its prompt ids the same way so they sort with OpenCode's own and a
//! retried prompt reuses its id, which OpenCode treats idempotently.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const CHARS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const RANDOM_LEN: usize = 14;

static CLOCK: Mutex<(u64, u64)> = Mutex::new((0, 0));

/// A new ascending OpenCode message id.
pub fn message_id() -> String {
    format!("msg_{}", ascending(now_ms()))
}

fn ascending(timestamp: u64) -> String {
    let counter = {
        let mut clock = CLOCK.lock().unwrap_or_else(|poison| poison.into_inner());
        if clock.0 != timestamp {
            *clock = (timestamp, 0);
        }
        clock.1 += 1;
        clock.1
    };
    let current = (u128::from(timestamp) * 0x1000) + u128::from(counter);
    let mut out = String::with_capacity(12 + RANDOM_LEN);
    for index in 0..6 {
        let byte = (current >> (40 - 8 * index)) & 0xff;
        out.push_str(&format!("{byte:02x}"));
    }
    let random = uuid::Uuid::new_v4();
    let bytes = random.as_bytes();
    for byte in bytes.iter().take(RANDOM_LEN) {
        out.push(CHARS[usize::from(*byte) % CHARS.len()] as char);
    }
    out
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Whether a string is an OpenCode message id.
pub fn is_message_id(value: &str) -> bool {
    value.starts_with("msg_")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_sort_by_creation_and_match_opencode_shape() {
        let first = message_id();
        let second = message_id();
        assert!(first < second, "{first} < {second}");
        assert_eq!(first.len(), "msg_".len() + 26);
        assert!(is_message_id(&first));
        // Same encoding as OpenCode for a fixed clock.
        let encoded = ascending(1_700_000_000_000);
        // OpenCode keeps the low 48 bits of `timestamp * 0x1000 + counter`.
        let expected = (1_700_000_000_000u128 * 0x1000 + 1) & 0xffff_ffff_ffff;
        assert!(
            encoded.starts_with(&format!("{expected:012x}")),
            "{encoded}"
        );
    }
}
