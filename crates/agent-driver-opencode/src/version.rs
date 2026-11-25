//! OpenCode application versions the native driver serves.
//!
//! The native route talks to the shared OpenCode v2 service over its HTTP API.
//! The core it needs (prompt delivery, the durable session log, instruction
//! entries and client-hosted MCP) is present from [`CORE_FLOOR`]. Older v2
//! releases keep the ACP route; v1 and 0.x stay on bridge v1.

use semver::Version;

/// Oldest OpenCode release whose service API the native driver was qualified on.
pub const CORE_FLOOR: Version = Version::new(2, 2, 0);

/// First release that lists background jobs (`GET /api/experimental/job`,
/// with `sessionID`, `descendants`, `kind` and `status` filters).
pub const JOB_LIST: Version = Version::new(2, 2, 6);

/// First release that cancels a background job
/// (`POST /api/experimental/job/{id}/cancel`). A cancelled job sends no
/// completion notice, and cancelling a sub-agent's job interrupts the child.
pub const JOB_CANCEL: Version = Version::new(2, 4, 0);

/// Parses what `opencode --version` or `/api/info` reports.
pub fn parse(text: &str) -> Option<Version> {
    inline_agent_driver_acp::parse_opencode_version(text)
}

/// Whether the native driver can run against this version.
pub fn native_supported(version: &Version) -> bool {
    version.major == 2 && *version >= CORE_FLOOR
}

/// Whether the service reporting `text` has what arrived in `floor`. An
/// unreadable version has nothing beyond the core.
pub fn at_least(text: &str, floor: &Version) -> bool {
    parse(text).is_some_and(|version| version >= *floor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_current_v2_releases_take_the_native_route() {
        for (text, supported) in [
            ("2.2.5", true),
            ("opencode v2.2.0", true),
            ("2.3.0-beta.1", true),
            ("2.1.4", false),
            ("2.0.32", false),
            ("1.19.5", false),
            ("3.0.0", false),
        ] {
            let version = parse(text).expect(text);
            assert_eq!(native_supported(&version), supported, "{text}");
        }
        assert!(parse("dev").is_none());
    }

    #[test]
    fn background_job_routes_follow_the_release_that_added_them() {
        assert!(!at_least("2.2.5", &JOB_LIST));
        assert!(at_least("2.2.6", &JOB_LIST));
        assert!(at_least("2.3.2", &JOB_LIST));
        assert!(!at_least("2.3.2", &JOB_CANCEL));
        assert!(at_least("2.4.0", &JOB_CANCEL));
        assert!(!at_least("dev", &JOB_LIST));
    }
}
