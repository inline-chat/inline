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
    pub(super) stderr: String,
    pub(super) exit_code: Option<i32>,
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
    let writer = child.stdin.take();
    let stdout = child.stdout.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stdout was not available")
    })?;
    let stderr = child.stderr.take().ok_or_else(|| {
        io::Error::new(io::ErrorKind::BrokenPipe, "child stderr was not available")
    })?;
    let started = std::time::Instant::now();
    let label = program_label(executable);
    log::debug!(
        "setup subprocess started program={label} timeout_ms={}",
        timeout.as_millis()
    );
    // Start all four operations together. A child may write before reading its
    // input; serial stdin writes deadlock once either pipe fills.
    let result = tokio::time::timeout(timeout, async {
        tokio::join!(
            read_bounded(stdout, false),
            read_bounded(stderr, true),
            async {
                if let (Some(input), Some(mut writer)) = (stdin, writer) {
                    writer.write_all(input).await?;
                    writer.shutdown().await?;
                }
                Ok::<_, io::Error>(())
            },
            child.wait()
        )
    })
    .await;
    let (stdout, stderr, input_result, status) = match result {
        Ok(output) => output,
        Err(_) => {
            let _ = child.kill().await;
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "{label} setup command timed out after {} seconds",
                    timeout.as_secs()
                ),
            )
            .into());
        }
    };
    let (stdout, stdout_truncated) = stdout?;
    let (stderr, stderr_truncated) = stderr?;
    let status = status?;
    // A failed child can close stdin early; retain its real exit diagnostic.
    if status.success() {
        input_result?;
        if stdout_truncated {
            return Err(crate::errors::CliError {
                code: "setup_output_too_large",
                message: format!("{label} returned more than 64 KiB of stdout; its result cannot be safely decoded"),
                hint: Some("The command exited successfully but its output exceeded the safety limit. Inspect the provider directly before retrying setup.".into()),
                examples: Vec::new(),
            }.into());
        }
    }
    let mut stderr = crate::diagnostics::safe_text(&String::from_utf8_lossy(&stderr));
    if stderr_truncated {
        stderr.insert_str(0, "[stderr tail; earlier output omitted]\n");
    }
    log::debug!(
        "setup subprocess finished program={label} exit={:?} elapsed_ms={}",
        status.code(),
        started.elapsed().as_millis()
    );
    if !status.success() {
        log::debug!("setup subprocess failure: {stderr}");
    }
    Ok(CommandOutput {
        success: status.success(),
        stdout: String::from_utf8_lossy(&stdout).trim().to_string(),
        stderr,
        exit_code: status.code(),
    })
}

async fn read_bounded(
    mut reader: impl AsyncRead + Unpin,
    tail: bool,
) -> io::Result<(Vec<u8>, bool)> {
    let mut output = Vec::new();
    let mut truncated = false;
    let mut buffer = [0; 8192];
    loop {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        if tail {
            output.extend_from_slice(&buffer[..count]);
            if output.len() > MAX_OUTPUT_BYTES {
                truncated = true;
                output.drain(..output.len() - MAX_OUTPUT_BYTES);
            }
        } else {
            let remaining = MAX_OUTPUT_BYTES - output.len();
            truncated |= count > remaining;
            output.extend_from_slice(&buffer[..count.min(remaining)]);
        }
    }
    if tail && truncated {
        // The retained buffer can begin halfway through a credential-bearing
        // physical line, after its redaction label. Drop that incomplete line.
        if let Some(newline) = output.iter().position(|byte| *byte == b'\n') {
            output.drain(..=newline);
        } else {
            output.clear();
        }
    }
    Ok((output, truncated))
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
            "{} {label} command failed ({}): {}",
            program_label(executable),
            output
                .exit_code
                .map(|code| format!("exit {code}"))
                .unwrap_or_else(|| "terminated by signal".into()),
            if output.stderr.is_empty() {
                "no stderr diagnostic was returned"
            } else {
                &output.stderr
            }
        ))
        .into());
    }
    Ok(output.stdout)
}

fn scrub_inline_credentials(command: &mut Command) {
    // Nested Inline invocations must keep the selected local profile, but
    // providers must not inherit present or future Inline credentials/DSNs.
    let names = std::env::vars_os()
        .map(|(name, _)| name)
        .chain(command.as_std().get_envs().map(|(name, _)| name.to_owned()))
        .collect::<Vec<_>>();
    for name in names {
        let key = name.to_string_lossy();
        if key.starts_with("INLINE_")
            && !matches!(
                key.as_ref(),
                "INLINE_CLI_BIN"
                    | "INLINE_DATA_DIR"
                    | "INLINE_SECRETS_PATH"
                    | "INLINE_STATE_PATH"
                    | "INLINE_API_BASE_URL"
                    | "INLINE_REALTIME_URL"
                    | "INLINE_PROTOCOL_VERSION"
            )
        {
            command.env_remove(name);
        }
    }
}

fn program_label(executable: &Path) -> &str {
    executable
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("agent")
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn nested_commands_strip_unknown_inline_secrets_but_keep_profile_routing() {
        let mut command = Command::new("fixture");
        command
            .env("INLINE_FUTURE_AUTH_TOKEN", "fixture-secret")
            .env("INLINE_CLI_SENTRY_DSN", "fixture-dsn")
            .env("INLINE_CLI_BIN", "/fixture/inline")
            .env("INLINE_DATA_DIR", "/fixture/data");
        scrub_inline_credentials(&mut command);
        let environment = command
            .as_std()
            .get_envs()
            .collect::<std::collections::HashMap<_, _>>();
        assert_eq!(
            environment.get(OsStr::new("INLINE_FUTURE_AUTH_TOKEN")),
            Some(&None)
        );
        assert_eq!(
            environment.get(OsStr::new("INLINE_CLI_SENTRY_DSN")),
            Some(&None)
        );
        assert!(
            environment
                .get(OsStr::new("INLINE_CLI_BIN"))
                .unwrap()
                .is_some()
        );
        assert!(
            environment
                .get(OsStr::new("INLINE_DATA_DIR"))
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn drains_chatty_child_before_it_reads_large_stdin() {
        let input = vec![b'x'; 256 * 1024];
        let result = run(
            Path::new("/bin/sh"),
            &[],
            &[
                "-c",
                "head -c 131072 /dev/zero; cat >/dev/null; printf 'finished' >&2",
            ],
            Some(&input),
            Duration::from_secs(5),
        )
        .await;
        let error = result
            .err()
            .expect("stdout overflow must be explicit, not silently truncated JSON");
        assert!(error.to_string().contains("64 KiB"));
    }

    #[tokio::test]
    async fn truncated_stderr_cannot_expose_a_credential_suffix_without_its_label() {
        let output = format!(
            "Authorization: Bearer {}\ncertificate expired\n",
            "opaque".repeat(16_384)
        );
        let (tail, truncated) = read_bounded(output.as_bytes(), true).await.unwrap();
        assert!(truncated);
        let detail = crate::diagnostics::safe_text(&String::from_utf8(tail).unwrap());
        assert_eq!(detail, "certificate expired");
    }

    #[tokio::test]
    async fn retains_failure_exit_and_scrubbed_stderr() {
        let error = require_success(
            Path::new("/bin/sh"),
            &[],
            &[
                "-c",
                "printf 'certificate expired\\nTOKEN=fixture-secret' >&2; exit 23",
            ],
            None,
            Duration::from_secs(5),
        )
        .await
        .unwrap_err();
        let text = error.to_string();
        assert!(text.contains("exit 23"));
        assert!(text.contains("certificate expired"));
        assert!(!text.contains("fixture-secret"));
    }

    #[tokio::test]
    async fn timeout_includes_a_blocked_stdin_writer() {
        let input = vec![b'x'; 256 * 1024];
        let started = std::time::Instant::now();
        let result = run(
            Path::new("/bin/sh"),
            &[],
            &["-c", "exec sleep 10"],
            Some(&input),
            Duration::from_millis(50),
        )
        .await;
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
