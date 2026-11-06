//! Server-sent events decoding, matching OpenCode's own client: events end at
//! a blank line, `data:` lines join with newlines, every event is one JSON
//! value, and one event may not exceed 16 MiB.

use serde_json::Value;

/// Largest single event OpenCode's client accepts.
pub const MAX_EVENT_BYTES: usize = 16 * 1024 * 1024;

/// Incremental SSE decoder. Bytes are buffered whole and decoded per
/// complete event, so a multi-byte character split across network chunks
/// is never mangled.
#[derive(Debug, Default)]
pub struct SseDecoder {
    buffer: Vec<u8>,
    pending_cr: bool,
}

/// Why a stream cannot continue.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SseError {
    #[error("an event exceeded {MAX_EVENT_BYTES} bytes")]
    TooLarge,
    #[error("an event was not valid JSON: {0}")]
    Malformed(String),
}

impl SseDecoder {
    /// Feeds bytes and returns every complete event.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Value>, SseError> {
        for &byte in bytes {
            match byte {
                b'\r' => {
                    self.buffer.push(b'\n');
                    self.pending_cr = true;
                    continue;
                }
                b'\n' if self.pending_cr => {}
                other => self.buffer.push(other),
            }
            self.pending_cr = false;
        }
        if self.buffer.len() > MAX_EVENT_BYTES {
            return Err(SseError::TooLarge);
        }
        self.drain(false)
    }

    /// Flushes a final event at end of stream.
    pub fn finish(&mut self) -> Result<Vec<Value>, SseError> {
        self.drain(true)
    }

    fn drain(&mut self, finished: bool) -> Result<Vec<Value>, SseError> {
        if finished && !self.buffer.is_empty() {
            self.buffer.extend_from_slice(b"\n\n");
        }
        let mut events = Vec::new();
        while let Some(boundary) = self.buffer.windows(2).position(|pair| pair == b"\n\n") {
            let block: Vec<u8> = self.buffer.drain(..boundary + 2).collect();
            let block = String::from_utf8_lossy(&block[..boundary]);
            let data = block
                .split('\n')
                .filter_map(|line| line.strip_prefix("data:"))
                .map(str::trim_start)
                .collect::<Vec<_>>()
                .join("\n");
            if data.is_empty() {
                continue;
            }
            events.push(
                serde_json::from_str(&data)
                    .map_err(|error| SseError::Malformed(error.to_string()))?,
            );
        }
        Ok(events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn splits_across_chunks_and_line_endings() {
        let mut decoder = SseDecoder::default();
        assert!(decoder.feed(b"data: {\"a\":").unwrap().is_empty());
        let events = decoder
            .feed(b"1}\r\n\r\n: comment\n\ndata: {\"b\":\ndata: 2}\n\n")
            .unwrap();
        assert_eq!(events, vec![json!({"a": 1}), json!({"b": 2})]);
        assert!(decoder.feed(b"data: {\"c\":3}").unwrap().is_empty());
        assert_eq!(decoder.finish().unwrap(), vec![json!({"c": 3})]);
    }

    #[test]
    fn keeps_characters_split_across_chunks() {
        let mut decoder = SseDecoder::default();
        let event = "data: {\"text\":\"héllo 🍍\"}\n\n".as_bytes();
        // Split inside the two-byte é and the four-byte emoji.
        let split = event.iter().position(|byte| *byte == 0xc3).unwrap() + 1;
        let emoji = event.iter().position(|byte| *byte == 0xf0).unwrap() + 2;
        assert!(decoder.feed(&event[..split]).unwrap().is_empty());
        assert!(decoder.feed(&event[split..emoji]).unwrap().is_empty());
        assert_eq!(
            decoder.feed(&event[emoji..]).unwrap(),
            vec![json!({"text": "héllo 🍍"})]
        );
    }

    #[test]
    fn rejects_malformed_events() {
        let mut decoder = SseDecoder::default();
        assert!(matches!(
            decoder.feed(b"data: nope\n\n"),
            Err(SseError::Malformed(_))
        ));
    }
}
