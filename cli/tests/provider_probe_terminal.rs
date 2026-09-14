#![cfg(unix)]

use std::fs::File;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

fn executable(path: &std::path::Path, contents: &str) {
    std::fs::write(path, contents).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn pseudo_terminal() -> (OwnedFd, OwnedFd) {
    let mut master = -1;
    let mut slave = -1;
    // openpty initializes both owned descriptors on success.
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0,
        "{}",
        std::io::Error::last_os_error()
    );
    let descriptors = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    // The Inline child needs only its stdin duplicate, not either original fd.
    for descriptor in [master, slave] {
        assert_eq!(
            unsafe { libc::fcntl(descriptor, libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    descriptors
}

#[test]
fn claude_preflight_is_noninteractive_with_and_without_a_controlling_terminal() {
    let directory = tempfile::tempdir().unwrap();
    executable(
        &directory.path().join("node"),
        "#!/bin/sh\nprintf 'v22.0.0'\n",
    );
    executable(
        &directory.path().join("claude"),
        r#"#!/bin/sh
[ "$1 $2" = 'auth status' ] || exit 70
if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
    printf 'probe inherited terminal stdio' >&2
    exit 71
fi
if (exec 3</dev/tty) 2>/dev/null; then
    printf 'probe inherited a controlling terminal' >&2
    exit 72
fi
printf '{"loggedIn":true}'
"#,
    );

    for controlling_terminal in [false, true] {
        for term in [
            None,
            Some("dumb"),
            Some("xterm-256color"),
            Some("screen-256color"),
        ] {
            let mut command = Command::new(env!("CARGO_BIN_EXE_inline"));
            command
                .args([
                    "--json",
                    "--compact",
                    "agents",
                    "setup",
                    "--target",
                    "claude",
                    "--dry-run",
                    "--no-install",
                    "--no-restart",
                    "--non-interactive",
                ])
                .env("PATH", directory.path())
                .env("INLINE_CLI_TELEMETRY", "off")
                .env("INLINE_DATA_DIR", directory.path().join("data"))
                .env("FORCE_COLOR", "1")
                .env("CLICOLOR_FORCE", "1")
                .env("TMUX", "/tmp/synthetic-tmux,1,0")
                .env("TMUX_PANE", "%1")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            if let Some(term) = term {
                command.env("TERM", term);
            } else {
                command.env_remove("TERM");
            }

            let _master = if controlling_terminal {
                let (master, slave) = pseudo_terminal();
                command.stdin(File::from(slave));
                // Give Inline a real foreground controlling terminal. Its
                // provider must independently detach from this session.
                unsafe {
                    command.pre_exec(|| {
                        if libc::setsid() == -1
                            || libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY as _, 0) == -1
                        {
                            return Err(std::io::Error::last_os_error());
                        }
                        Ok(())
                    });
                }
                Some(master)
            } else {
                unsafe {
                    command.pre_exec(|| {
                        if libc::setsid() == -1 {
                            return Err(std::io::Error::last_os_error());
                        }
                        Ok(())
                    });
                }
                None
            };
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "controlling_terminal={controlling_terminal}, TERM={term:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            let payload: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(payload["target"], "claude");
        }
    }
}
