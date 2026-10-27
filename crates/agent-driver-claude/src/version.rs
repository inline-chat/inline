//! The installed CLI's version and protocol capabilities.

use std::cmp::Ordering;
use std::fmt;
use std::path::Path;
use std::time::Duration;

use crate::options::CommandSpec;

/// A Claude Code release, `major.minor.patch`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ClaudeVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl ClaudeVersion {
    pub const fn new(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    /// Parses the leading `x.y.z` of `claude --version` output such as
    /// `2.1.292 (Claude Code)`.
    pub fn parse(text: &str) -> Option<Self> {
        let start = text.find(|c: char| c.is_ascii_digit())?;
        let mut parts = text[start..]
            .split(|c: char| !c.is_ascii_digit() && c != '.')
            .next()?
            .split('.');
        let major = parts.next()?.parse().ok()?;
        let minor = parts.next()?.parse().ok()?;
        let patch = parts.next()?.parse().ok()?;
        Some(Self::new(major, minor, patch))
    }

    pub fn at_least(self, other: Self) -> bool {
        self.cmp(&other) != Ordering::Less
    }
}

impl fmt::Display for ClaudeVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// `client_composed` (verbatim prompts) is honoured from this release.
pub const CLIENT_COMPOSED_MIN: ClaudeVersion = ClaudeVersion::new(2, 1, 248);

/// `shouldQuery: false` is honoured (verified from the 2.1.292 lab baseline;
/// 2.0.32 runs a turn for it). Older CLIs get no passive delivery.
pub const PASSIVE_MIN: ClaudeVersion = ClaudeVersion::new(2, 1, 292);

/// Protocol capabilities `system/init` advertises.
pub mod capability {
    /// The interrupt response lists `still_queued`.
    pub const INTERRUPT_RECEIPT: &str = "interrupt_receipt_v1";
    /// The interrupt honours `cancel_queued`.
    pub const INTERRUPT_CANCEL_QUEUED: &str = "interrupt_cancel_queued_v1";
    pub const UI_SURFACE: &str = "ui_surface_v1";
}

/// Runs `<claude> --version` with the launch environment.
pub async fn probe(
    spec: &CommandSpec,
    timeout: Duration,
) -> std::io::Result<(ClaudeVersion, String)> {
    let mut command = tokio::process::Command::new(&spec.program);
    command
        .arg("--version")
        .current_dir(existing_dir(&spec.cwd))
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    for name in &spec.env_remove {
        command.env_remove(name);
    }
    for (name, value) in &spec.env_set {
        command.env(name, value);
    }
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "claude --version timed out")
        })??;
    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let version = ClaudeVersion::parse(&text).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("unrecognized claude --version output: {text:?}"),
        )
    })?;
    Ok((version, text))
}

fn existing_dir(path: &Path) -> &Path {
    if path.is_dir() { path } else { Path::new("/") }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cli_version_output() {
        assert_eq!(
            ClaudeVersion::parse("2.1.292 (Claude Code)"),
            Some(ClaudeVersion::new(2, 1, 292))
        );
        assert_eq!(
            ClaudeVersion::parse("claude 2.0.32-beta"),
            Some(ClaudeVersion::new(2, 0, 32))
        );
        assert_eq!(ClaudeVersion::parse("Claude Code"), None);
        assert!(ClaudeVersion::new(2, 1, 292).at_least(CLIENT_COMPOSED_MIN));
        assert!(!ClaudeVersion::new(2, 0, 32).at_least(CLIENT_COMPOSED_MIN));
    }
}
