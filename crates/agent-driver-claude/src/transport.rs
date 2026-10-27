//! The CLI subprocess: NDJSON over stdin/stdout, stderr kept for diagnosis.

use std::collections::VecDeque;
use std::io;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

use crate::options::CommandSpec;

/// One message larger than this is refused (a safety cap, far above any
/// real frame; images and long tool results are a few MiB at most).
pub const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;
/// How much of stderr is kept for startup-failure reports.
pub const STDERR_TAIL_BYTES: usize = 64 * 1024;

/// The writable half of the transport.
pub type BoxWriter = Box<dyn AsyncWrite + Send + Unpin>;
/// The readable half of the transport.
pub type BoxReader = Box<dyn AsyncBufRead + Send + Unpin>;

/// The last bytes the CLI wrote to stderr.
#[derive(Clone, Debug, Default)]
pub struct StderrTail {
    inner: Arc<Mutex<VecDeque<u8>>>,
}

impl StderrTail {
    fn push(&self, bytes: &[u8]) {
        let mut tail = self
            .inner
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        tail.extend(bytes);
        let overflow = tail.len().saturating_sub(STDERR_TAIL_BYTES);
        tail.drain(..overflow);
    }

    pub fn text(&self) -> String {
        let tail = self
            .inner
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let bytes: Vec<u8> = tail.iter().copied().collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

/// A spawned CLI process and its pipes.
pub struct SpawnedProcess {
    pub child: Child,
    pub stdin: BoxWriter,
    pub stdout: BoxReader,
    pub stderr: StderrTail,
}

/// Spawns the CLI in its own process group, with a scrubbed environment.
pub fn spawn(spec: &CommandSpec) -> io::Result<SpawnedProcess> {
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .current_dir(&spec.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for name in &spec.env_remove {
        command.env_remove(name);
    }
    for (name, value) in &spec.env_set {
        command.env(name, value);
    }
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn()?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("CLI stdin was not piped"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("CLI stdout was not piped"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("CLI stderr was not piped"))?;
    let tail = StderrTail::default();
    tokio::spawn(drain_stderr(stderr, tail.clone()));
    Ok(SpawnedProcess {
        child,
        stdin: Box::new(stdin),
        stdout: Box::new(BufReader::with_capacity(256 * 1024, stdout)),
        stderr: tail,
    })
}

async fn drain_stderr(stderr: impl AsyncRead + Unpin, tail: StderrTail) {
    let mut reader = BufReader::new(stderr);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {
                tail.push(&line);
                log::debug!(
                    target: "inline_agent_driver_claude::stderr",
                    "{}",
                    String::from_utf8_lossy(&line).trim_end()
                );
            }
        }
    }
}

/// Reads one newline-terminated line, refusing lines over `MAX_LINE_BYTES`.
/// Returns `Ok(false)` at end of stream (after any unterminated tail).
pub async fn read_line(reader: &mut BoxReader, line: &mut Vec<u8>) -> io::Result<bool> {
    line.clear();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(!line.is_empty());
        }
        let (chunk, done) = match memchr(available) {
            Some(index) => (&available[..=index], true),
            None => (available, false),
        };
        if line.len() + chunk.len() > MAX_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("CLI message exceeded {MAX_LINE_BYTES} bytes"),
            ));
        }
        line.extend_from_slice(chunk);
        let consumed = chunk.len();
        reader.consume(consumed);
        if done {
            return Ok(true);
        }
    }
}

fn memchr(bytes: &[u8]) -> Option<usize> {
    bytes.iter().position(|byte| *byte == b'\n')
}

/// Writes one JSON line and flushes.
pub async fn write_line(writer: &mut BoxWriter, json: &str) -> io::Result<()> {
    writer.write_all(json.as_bytes()).await?;
    writer.write_all(b"\n").await?;
    writer.flush().await
}

/// Waits for exit after stdin closed, then escalates: SIGTERM to the group,
/// then SIGKILL. The grace lets the CLI flush its session file.
pub async fn shut_down(child: &mut Child, grace: Duration) -> io::Result<ExitStatus> {
    if let Ok(status) = tokio::time::timeout(grace, child.wait()).await {
        return status;
    }
    signal_group(child, Signal::Terminate);
    if let Ok(status) = tokio::time::timeout(grace, child.wait()).await {
        return status;
    }
    signal_group(child, Signal::Kill);
    child.wait().await
}

#[derive(Clone, Copy)]
enum Signal {
    Terminate,
    Kill,
}

fn signal_group(child: &mut Child, signal: Signal) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        let signal = match signal {
            Signal::Terminate => libc::SIGTERM,
            Signal::Kill => libc::SIGKILL,
        };
        // The child leads its own group (spawned with process_group(0)).
        unsafe {
            libc::killpg(pid as libc::pid_t, signal);
        }
        return;
    }
    let _ = signal;
    let _ = child.start_kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(bytes: &'static [u8]) -> BoxReader {
        Box::new(BufReader::with_capacity(4, bytes))
    }

    #[tokio::test]
    async fn lines_span_buffer_refills() {
        let mut stream = reader(b"{\"type\":\"a\"}\n{\"type\":\"b\"}\ntail");
        let mut line = Vec::new();
        assert!(read_line(&mut stream, &mut line).await.unwrap());
        assert_eq!(line, b"{\"type\":\"a\"}\n");
        assert!(read_line(&mut stream, &mut line).await.unwrap());
        assert_eq!(line, b"{\"type\":\"b\"}\n");
        assert!(read_line(&mut stream, &mut line).await.unwrap());
        assert_eq!(line, b"tail");
        assert!(!read_line(&mut stream, &mut line).await.unwrap());
    }

    #[test]
    fn stderr_tail_keeps_the_end() {
        let tail = StderrTail::default();
        tail.push(&vec![b'a'; STDERR_TAIL_BYTES]);
        tail.push(b"end");
        let text = tail.text();
        assert_eq!(text.len(), STDERR_TAIL_BYTES);
        assert!(text.ends_with("end"));
    }
}
