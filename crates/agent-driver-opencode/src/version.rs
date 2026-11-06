//! OpenCode application versions the native driver serves.
//!
//! The native route talks to the shared OpenCode v2 service over its HTTP API.
//! The core it needs (prompt delivery, the durable session log, instruction
//! entries and client-hosted MCP) is present from [`CORE_FLOOR`]. Older v2
//! releases keep the ACP route; v1 and 0.x stay on bridge v1.

use semver::Version;

/// Oldest OpenCode release whose service API the native driver was qualified on.
pub const CORE_FLOOR: Version = Version::new(2, 2, 0);

/// Parses what `opencode --version` or `/api/info` reports.
pub fn parse(text: &str) -> Option<Version> {
    inline_agent_driver_acp::parse_opencode_version(text)
}

/// Whether the native driver can run against this version.
pub fn native_supported(version: &Version) -> bool {
    version.major == 2 && *version >= CORE_FLOOR
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
}
