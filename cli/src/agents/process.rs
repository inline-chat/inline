use std::ffi::{OsStr, OsString};
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

const MAX_OUTPUT_BYTES: usize = 64 * 1024;

pub(super) struct CommandOutput {
    pub(super) success: bool,
    pub(super) stdout: String,
}

pub(super) async fn run(
    executable: &Path,
    prefix: &[OsString],
    args: &[&str],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<CommandOutput, Box<dyn std::error::Error>> {
    run_with_environment(executable, prefix, args, stdin, timeout, &[]).await
}

pub(super) async fn run_with_environment(
    executable: &Path,
    prefix: &[OsString],
    args: &[&str],
    stdin: Option<&[u8]>,
    timeout: Duration,
    environment: &[(OsString, OsString)],
) -> Result<CommandOutput, Box<dyn std::error::Error>> {
    let mut command = Command::new(executable);
    command
        .args(prefix)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .env("NO_COLOR", "1")
        .envs(environment.iter().map(|(name, value)| (name, value)));
    scrub_inline_credentials(&mut command);
    let mut child = command.spawn().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("could not start {}: {error}", executable.display()),
        )
    })?;
    if let Some(input) = stdin {
        let mut writer = child.stdin.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::BrokenPipe, "child stdin was not available")
        })?;
        writer.write_all(input).await?;
        writer.shutdown().await?;
    }
    let stdout = child.stdout.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stdout was not available")
    })?;
    let stderr = child.stderr.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stderr was not available")
    })?;
    let (stdout, stderr, status) = tokio::time::timeout(timeout, async {
        tokio::try_join!(read_bounded(stdout), read_bounded(stderr), child.wait())
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "agent setup command timed out"))??;
    if stdout.len() > MAX_OUTPUT_BYTES || stderr.len() > MAX_OUTPUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "agent setup command output exceeded the safety limit",
        )
        .into());
    }
    Ok(CommandOutput {
        success: status.success(),
        stdout: String::from_utf8_lossy(&stdout).trim().to_string(),
    })
}

async fn read_bounded(reader: impl AsyncRead + Unpin) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    reader
        .take((MAX_OUTPUT_BYTES + 1) as u64)
        .read_to_end(&mut output)
        .await?;
    Ok(output)
}

pub(super) async fn require_success(
    executable: &Path,
    prefix: &[OsString],
    args: &[&str],
    stdin: Option<&[u8]>,
    timeout: Duration,
) -> Result<String, Box<dyn std::error::Error>> {
    require_success_with_environment(executable, prefix, args, stdin, timeout, &[]).await
}

pub(super) async fn require_success_with_environment(
    executable: &Path,
    prefix: &[OsString],
    args: &[&str],
    stdin: Option<&[u8]>,
    timeout: Duration,
    environment: &[(OsString, OsString)],
) -> Result<String, Box<dyn std::error::Error>> {
    let output =
        run_with_environment(executable, prefix, args, stdin, timeout, environment).await?;
    if !output.success {
        let label = args.first().copied().unwrap_or("command");
        return Err(io::Error::other(format!(
            "{} {label} command failed",
            program_label(executable)
        ))
        .into());
    }
    Ok(output.stdout)
}

fn scrub_inline_credentials(command: &mut Command) {
    for name in [
        "INLINE_TOKEN",
        "INLINE_BOT_TOKEN",
        "INLINE_OWNER_TOKEN",
        "INLINE_ACCESS_TOKEN",
    ] {
        command.env_remove(name);
    }
}

fn program_label(executable: &Path) -> &str {
    executable
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("agent")
}
