//! OpenCode application versions are independent of the ACP wire version.

pub const OPENCODE_MIGRATION_URL: &str = "https://opencode.ai/v2/docs/migrate-v1/";

pub const OPENCODE_V1_GUIDANCE: &str = "OpenCode v1 continues on the legacy Inline bridge. Upgrade to OpenCode v2 using https://opencode.ai/v2/docs/migrate-v1/, then rerun `inline setup opencode` to use bridge v2. Your OpenCode configuration is not changed by Inline.";

/// Existing installations keep v1 compatibility during migration. New setup
/// and the bridge v2 route use the stricter `require_opencode_v2` check.
pub fn require_supported_opencode_version(output: &str) -> Result<semver::Version, String> {
    let version = parse_opencode_version(output).ok_or_else(|| {
        "OpenCode returned an unrecognized version; install OpenCode v2 and rerun `inline setup opencode`".to_string()
    })?;
    if !matches!(version.major, 1 | 2) {
        return Err(format!(
            "OpenCode {version} is unsupported; install OpenCode v2 and rerun `inline setup opencode`"
        ));
    }
    Ok(version)
}

/// Accept the two released CLI forms and the bare ACP agent-info version.
/// Do not infer a major version from a binary name or an arbitrary banner.
pub fn parse_opencode_version(output: &str) -> Option<semver::Version> {
    let version = output.trim();
    let version = version.strip_prefix("opencode ").unwrap_or(version);
    semver::Version::parse(version.strip_prefix('v').unwrap_or(version)).ok()
}

pub fn require_opencode_v2(output: &str) -> Result<semver::Version, String> {
    let version = parse_opencode_version(output).ok_or_else(|| {
        "OpenCode returned an unrecognized version; install OpenCode v2 and rerun `inline setup opencode`".to_string()
    })?;
    if version.major != 2 {
        return Err(format!(
            "OpenCode {version} is unsupported: Inline requires OpenCode v2. Migrate using {OPENCODE_MIGRATION_URL}, then rerun `inline setup opencode`"
        ));
    }
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distinguishes_released_cli_and_agent_info_versions() {
        for (output, major) in [
            ("1.19.4", 1),
            ("opencode v2.0.32\n", 2),
            ("v2.2.0", 2),
            ("2.0.0-beta.1", 2),
        ] {
            assert_eq!(parse_opencode_version(output).unwrap().major, major);
        }
        for output in [
            "opencode2",
            "2",
            "2.0",
            "dev",
            "warning 2.0.32",
            "opencode v2.0.32\nwarning",
            "other-cli 2.0.32",
        ] {
            assert!(parse_opencode_version(output).is_none(), "{output}");
        }
    }

    #[test]
    fn supports_only_v2_and_gives_v1_users_a_migration_path() {
        assert!(require_opencode_v2("opencode v2.0.32").is_ok());
        for version in ["1.19.4", "3.0.0"] {
            let error = require_opencode_v2(version).unwrap_err();
            assert!(error.contains(version));
            assert!(error.contains(OPENCODE_MIGRATION_URL));
            assert!(error.contains("inline setup opencode"));
        }
        assert!(require_opencode_v2("dev").is_err());
    }
}
