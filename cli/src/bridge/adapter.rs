//! Explicit, immutable installation of curated ACP npm adapters.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use inline_agent_driver_acp::{
    AcpDistribution, AcpProviderSupport, EmbeddedAdapterDistribution, NpmAdapterDistribution,
    should_scrub_acp_environment_name,
};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{BridgePaths, ensure_private_dir, is_executable_file, resolve_executable};

const MAX_PACKAGE_LOCK_BYTES: u64 = 8 * 1024 * 1024;
const CLAUDE_PACKAGE_JSON: &[u8] = include_bytes!("adapter_locks/claude/package.json");
const CLAUDE_PACKAGE_LOCK: &[u8] = include_bytes!("adapter_locks/claude/package-lock.json");
const AMP_PACKAGE_JSON: &[u8] = include_bytes!("adapter_locks/amp/package.json");
const AMP_PACKAGE_LOCK: &[u8] = include_bytes!("adapter_locks/amp/package-lock.json");
const AMP_EXECUTABLE: &[u8] = include_bytes!("adapter_locks/amp/dist/index.js");
const AMP_LICENSE: &[u8] = include_bytes!("adapter_locks/amp/LICENSE");

#[derive(Clone, Copy)]
struct EmbeddedAdapterArtifact {
    executable_path: &'static str,
    executable: &'static [u8],
    license_path: &'static str,
    license: &'static [u8],
}

#[derive(Clone, Copy)]
struct PinnedAdapterManifest {
    package_json: &'static [u8],
    package_lock: &'static [u8],
    embedded: Option<EmbeddedAdapterArtifact>,
}

fn npm_ci_arguments(embedded: bool) -> Vec<&'static str> {
    let mut arguments = vec!["ci", "--ignore-scripts", "--omit=dev"];
    if embedded {
        arguments.push("--omit=optional");
    }
    arguments.extend(["--no-audit", "--no-fund", "--prefix"]);
    arguments
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PreparedAdapter {
    pub(super) executable: PathBuf,
    pub(super) version: &'static str,
    pub(super) installed_now: bool,
}

pub(super) fn prepare_pinned_adapter(
    paths: &BridgePaths,
    support: &AcpProviderSupport,
    allow_install: bool,
) -> Result<Option<PreparedAdapter>, String> {
    let (version, npm_distribution, embedded_distribution) = match support.distribution {
        AcpDistribution::Native => return Ok(None),
        AcpDistribution::NpmAdapter(distribution) => {
            let integrity = distribution.integrity.ok_or_else(|| {
                format!(
                    "{} adapter {}@{} has no verified integrity pin",
                    support.display_name, distribution.package, distribution.registry_version
                )
            })?;
            (
                distribution.registry_version,
                Some((distribution, integrity)),
                None,
            )
        }
        AcpDistribution::EmbeddedAdapter(distribution) => {
            (distribution.version, None, Some(distribution))
        }
    };
    let manifest = pinned_adapter_manifest(support.provider_id)?;
    let install_root = paths
        .root
        .join("adapters")
        .join(support.provider_id)
        .join(version);
    ensure_private_dir(&install_root).map_err(|error| {
        format!(
            "could not prepare the private {} adapter directory: {error}",
            support.display_name
        )
    })?;

    if let Ok(executable) = verify_adapter_install(
        &install_root,
        support.executable,
        npm_distribution,
        embedded_distribution,
        manifest,
    ) {
        return Ok(Some(PreparedAdapter {
            executable,
            version,
            installed_now: false,
        }));
    }

    if !allow_install {
        return Err(format!(
            "the verified {} ACP adapter is not installed and --no-install was provided",
            support.display_name
        ));
    }

    let npm = resolve_executable(Path::new("npm"))
        .map_err(|_| "npm is required to install the curated ACP adapter".to_string())?;
    fs::write(install_root.join("package.json"), manifest.package_json)
        .map_err(|error| format!("could not write Inline's pinned adapter manifest: {error}"))?;
    fs::write(
        install_root.join("package-lock.json"),
        manifest.package_lock,
    )
    .map_err(|error| format!("could not write Inline's pinned adapter dependency lock: {error}"))?;
    let mut command = Command::new(npm);
    // Embedded Amp uses the separately verified host CLI through AMP_CLI_PATH;
    // its SDK's optional bundled native CLI must never become a fallback.
    command
        .current_dir(&install_root)
        .args(npm_ci_arguments(embedded_distribution.is_some()))
        .arg(&install_root);
    for (name, _) in std::env::vars_os() {
        if should_scrub_acp_environment_name(&name, "adapter-install") {
            command.env_remove(name);
        }
    }
    let output = command.output().map_err(|error| {
        format!(
            "could not start npm while installing {}: {error}",
            support.display_name
        )
    })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "verified {} adapter install failed: {}",
            support.display_name,
            super::safe_diagnostic(&stderr)
        ));
    }
    write_embedded_artifact(&install_root, manifest)?;
    let executable = verify_adapter_install(
        &install_root,
        support.executable,
        npm_distribution,
        embedded_distribution,
        manifest,
    )?;
    Ok(Some(PreparedAdapter {
        executable,
        version,
        installed_now: true,
    }))
}

/// Revalidates a persisted adapter executable against the manifests embedded
/// in this CLI. Service startup uses this instead of trusting directory names
/// or a setup-time check from an older CLI version.
pub(super) fn verify_pinned_adapter_executable(
    provider_id: &str,
    executable: &Path,
) -> Result<PathBuf, String> {
    let support = inline_agent_driver_acp::provider_support(provider_id)
        .ok_or_else(|| format!("{provider_id} has no curated ACP adapter"))?;
    let (version, npm_distribution, embedded_distribution) = match support.distribution {
        AcpDistribution::Native => {
            return Err(format!("{provider_id} does not use a pinned ACP adapter"));
        }
        AcpDistribution::NpmAdapter(distribution) => {
            let integrity = distribution.integrity.ok_or_else(|| {
                format!(
                    "{} adapter has no verified integrity pin",
                    support.display_name
                )
            })?;
            (
                distribution.registry_version,
                Some((distribution, integrity)),
                None,
            )
        }
        AcpDistribution::EmbeddedAdapter(distribution) => {
            (distribution.version, None, Some(distribution))
        }
    };
    let executable = fs::canonicalize(executable)
        .map_err(|_| "adapter executable is missing after installation".to_string())?;
    let install_root = executable
        .ancestors()
        .find(|candidate| {
            candidate.file_name().is_some_and(|name| name == version)
                && candidate
                    .parent()
                    .and_then(Path::file_name)
                    .is_some_and(|name| name == provider_id)
                && candidate
                    .parent()
                    .and_then(Path::parent)
                    .and_then(Path::file_name)
                    .is_some_and(|name| name == "adapters")
        })
        .ok_or_else(|| "adapter executable is outside Inline's pinned install".to_string())?;
    let verified = verify_adapter_install(
        install_root,
        support.executable,
        npm_distribution,
        embedded_distribution,
        pinned_adapter_manifest(provider_id)?,
    )?;
    if verified != executable {
        return Err("adapter executable does not match Inline's pinned install".to_string());
    }
    Ok(verified)
}

/// Returns whether a configured path names this CLI's current managed adapter
/// slot. Verification failures inside that slot are integrity failures, not a
/// compatibility signal for an older install.
pub(super) fn targets_current_pinned_adapter(provider_id: &str, executable: &Path) -> bool {
    let Some(support) = inline_agent_driver_acp::provider_support(provider_id) else {
        return false;
    };
    let version = match support.distribution {
        AcpDistribution::Native => return false,
        AcpDistribution::NpmAdapter(distribution) => distribution.registry_version,
        AcpDistribution::EmbeddedAdapter(distribution) => distribution.version,
    };
    executable.ancestors().any(|candidate| {
        candidate.file_name().is_some_and(|name| name == version)
            && candidate
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|name| name == provider_id)
            && candidate
                .parent()
                .and_then(Path::parent)
                .and_then(Path::file_name)
                .is_some_and(|name| name == "adapters")
    })
}

fn pinned_adapter_manifest(provider_id: &str) -> Result<PinnedAdapterManifest, String> {
    match provider_id {
        "claude" => Ok(PinnedAdapterManifest {
            package_json: CLAUDE_PACKAGE_JSON,
            package_lock: CLAUDE_PACKAGE_LOCK,
            embedded: None,
        }),
        "amp" => Ok(PinnedAdapterManifest {
            package_json: AMP_PACKAGE_JSON,
            package_lock: AMP_PACKAGE_LOCK,
            embedded: Some(EmbeddedAdapterArtifact {
                executable_path: "dist/index.js",
                executable: AMP_EXECUTABLE,
                license_path: "LICENSE",
                license: AMP_LICENSE,
            }),
        }),
        _ => Err(format!(
            "{provider_id} adapter setup is withheld until Inline ships a complete dependency lock"
        )),
    }
}

fn verify_adapter_install(
    install_root: &Path,
    executable_name: &str,
    npm_distribution: Option<(NpmAdapterDistribution, &str)>,
    embedded_distribution: Option<EmbeddedAdapterDistribution>,
    manifest: PinnedAdapterManifest,
) -> Result<PathBuf, String> {
    let package_json = fs::read(install_root.join("package.json"))
        .map_err(|_| "adapter package manifest is missing or incomplete".to_string())?;
    if package_json != manifest.package_json {
        return Err("adapter package manifest does not match Inline's pin".to_string());
    }
    let lock_path = install_root.join("package-lock.json");
    let metadata = fs::metadata(&lock_path)
        .map_err(|_| "adapter package lock is missing or incomplete".to_string())?;
    if metadata.len() > MAX_PACKAGE_LOCK_BYTES {
        return Err("adapter package lock exceeds the safety limit".to_string());
    }
    let lock_bytes =
        fs::read(&lock_path).map_err(|error| format!("could not read adapter lock: {error}"))?;
    if lock_bytes != manifest.package_lock {
        return Err("adapter dependency lock does not match Inline's pin".to_string());
    }
    let lock: Value = serde_json::from_slice(&lock_bytes)
        .map_err(|error| format!("adapter package lock is invalid: {error}"))?;
    let root = fs::canonicalize(install_root)
        .map_err(|error| format!("could not resolve adapter directory: {error}"))?;
    let executable = if let Some((distribution, expected_integrity)) = npm_distribution {
        let package_key = format!("node_modules/{}", distribution.package);
        let package = lock
            .get("packages")
            .and_then(|packages| packages.get(&package_key))
            .ok_or_else(|| "adapter package lock omitted the pinned package".to_string())?;
        if package.get("version").and_then(Value::as_str) != Some(distribution.registry_version) {
            return Err("adapter package lock has an unexpected version".to_string());
        }
        if package.get("integrity").and_then(Value::as_str) != Some(expected_integrity) {
            return Err("adapter package integrity does not match Inline's pin".to_string());
        }
        fs::canonicalize(install_root.join("node_modules/.bin").join(executable_name))
            .map_err(|_| "adapter executable is missing after installation".to_string())?
    } else if let Some(distribution) = embedded_distribution {
        let artifact = manifest
            .embedded
            .ok_or_else(|| "embedded adapter artifact is missing from Inline".to_string())?;
        let root_version = lock
            .get("packages")
            .and_then(|packages| packages.get(""))
            .and_then(|package| package.get("version"))
            .and_then(Value::as_str);
        if root_version != distribution.version.split('+').next() {
            return Err("embedded adapter lock has an unexpected version".to_string());
        }
        if lock
            .get("packages")
            .and_then(Value::as_object)
            .is_some_and(|packages| {
                packages.keys().any(|package| {
                    package.starts_with("node_modules/@ampcode/cli-")
                        && install_root.join(package).exists()
                })
            })
        {
            return Err(
                "embedded adapter install contains an optional bundled Amp runtime".to_string(),
            );
        }
        let executable_path = install_root.join(artifact.executable_path);
        let executable_bytes = fs::read(&executable_path)
            .map_err(|_| "embedded adapter executable is missing".to_string())?;
        if executable_bytes != artifact.executable {
            return Err("embedded adapter executable does not match Inline's pin".to_string());
        }
        let checksum = format!("sha256-{:x}", Sha256::digest(&executable_bytes));
        if checksum != distribution.checksum {
            return Err("embedded adapter checksum does not match Inline's pin".to_string());
        }
        let license = fs::read(install_root.join(artifact.license_path))
            .map_err(|_| "embedded adapter license is missing".to_string())?;
        if license != artifact.license {
            return Err("embedded adapter license does not match Inline's pin".to_string());
        }
        fs::canonicalize(executable_path)
            .map_err(|_| "embedded adapter executable is missing after installation".to_string())?
    } else {
        return Err("adapter distribution is missing".to_string());
    };
    if !executable.starts_with(&root) || !is_executable_file(&executable) {
        return Err(
            "adapter executable escaped its private install or is not executable".to_string(),
        );
    }
    Ok(executable)
}

fn write_embedded_artifact(
    install_root: &Path,
    manifest: PinnedAdapterManifest,
) -> Result<(), String> {
    let Some(artifact) = manifest.embedded else {
        return Ok(());
    };
    let executable = install_root.join(artifact.executable_path);
    let parent = executable
        .parent()
        .ok_or_else(|| "embedded adapter executable has no parent directory".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create embedded adapter directory: {error}"))?;
    fs::write(&executable, artifact.executable)
        .map_err(|error| format!("could not write embedded adapter executable: {error}"))?;
    #[cfg(unix)]
    {
        let mut permissions = fs::metadata(&executable)
            .map_err(|error| format!("could not inspect embedded adapter executable: {error}"))?
            .permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions)
            .map_err(|error| format!("could not secure embedded adapter executable: {error}"))?;
    }
    fs::write(install_root.join(artifact.license_path), artifact.license)
        .map_err(|error| format!("could not write embedded adapter license: {error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;

    const DISTRIBUTION: NpmAdapterDistribution = NpmAdapterDistribution {
        package: "@example/test-acp",
        registry_version: "1.2.3",
        integrity: Some("sha512-test"),
    };

    fn fixture() -> tempfile::TempDir {
        let root = tempfile::tempdir().expect("tempdir");
        let package = root.path().join("node_modules/@example/test-acp");
        let bin = root.path().join("node_modules/.bin");
        fs::create_dir_all(package.join("dist")).expect("package directory");
        fs::create_dir_all(&bin).expect("bin directory");
        let target = package.join("dist/index.js");
        fs::write(&target, "#!/usr/bin/env node\n").expect("adapter executable");
        let mut permissions = fs::metadata(&target).expect("metadata").permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&target, permissions).expect("executable mode");
        symlink("../@example/test-acp/dist/index.js", bin.join("test-acp"))
            .expect("adapter symlink");
        fs::write(root.path().join("package.json"), b"{\"private\":true}\n")
            .expect("write package manifest");
        fs::write(
            root.path().join("package-lock.json"),
            serde_json::to_vec(&serde_json::json!({
                "lockfileVersion": 3,
                "packages": {
                    "node_modules/@example/test-acp": {
                        "version": "1.2.3",
                        "integrity": "sha512-test"
                    }
                }
            }))
            .expect("package lock"),
        )
        .expect("write package lock");
        root
    }

    #[test]
    fn verifies_exact_lock_identity_and_contained_executable() {
        let root = fixture();
        let package_json = fs::read(root.path().join("package.json")).expect("manifest");
        let package_lock = fs::read(root.path().join("package-lock.json")).expect("lock");
        let manifest = PinnedAdapterManifest {
            package_json: Box::leak(package_json.into_boxed_slice()),
            package_lock: Box::leak(package_lock.into_boxed_slice()),
            embedded: None,
        };
        let executable = verify_adapter_install(
            root.path(),
            "test-acp",
            Some((DISTRIBUTION, "sha512-test")),
            None,
            manifest,
        )
        .expect("verified adapter");
        assert!(executable.starts_with(fs::canonicalize(root.path()).expect("root")));
    }

    #[test]
    fn persisted_claude_executable_is_revalidated_against_the_current_cli_pin() {
        let root = tempfile::tempdir().expect("tempdir");
        let install = root.path().join("adapters/claude/0.73.0");
        let package = install.join("node_modules/@agentclientprotocol/claude-agent-acp");
        let bin = install.join("node_modules/.bin");
        fs::create_dir_all(package.join("dist")).expect("package directory");
        fs::create_dir_all(&bin).expect("bin directory");
        fs::write(install.join("package.json"), CLAUDE_PACKAGE_JSON).expect("manifest");
        fs::write(install.join("package-lock.json"), CLAUDE_PACKAGE_LOCK).expect("lock");
        let target = package.join("dist/index.js");
        fs::write(&target, "#!/usr/bin/env node\n").expect("adapter executable");
        let mut permissions = fs::metadata(&target).expect("metadata").permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&target, permissions).expect("executable mode");
        symlink(
            "../@agentclientprotocol/claude-agent-acp/dist/index.js",
            bin.join("claude-agent-acp"),
        )
        .expect("adapter symlink");

        assert_eq!(
            verify_pinned_adapter_executable("claude", &target).expect("verified persisted pin"),
            fs::canonicalize(&target).expect("canonical target")
        );
        fs::write(install.join("package-lock.json"), b"{}\n").expect("tampered lock");
        assert!(
            verify_pinned_adapter_executable("claude", &target)
                .expect_err("tampered lock must be rejected")
                .contains("does not match Inline's pin")
        );
    }

    #[test]
    fn current_managed_slot_is_distinct_from_legacy_adapter_paths() {
        assert!(targets_current_pinned_adapter(
            "claude",
            Path::new("/private/bridge/adapters/claude/0.73.0/node_modules/.bin/claude-agent-acp")
        ));
        assert!(!targets_current_pinned_adapter(
            "claude",
            Path::new("/private/bridge/adapters/claude/0.63.0/node_modules/.bin/claude-agent-acp")
        ));
        assert!(!targets_current_pinned_adapter(
            "claude",
            Path::new("/usr/local/bin/claude-agent-acp")
        ));
    }

    #[test]
    fn rejects_registry_integrity_drift() {
        let root = fixture();
        let package_json = fs::read(root.path().join("package.json")).expect("manifest");
        let package_lock = fs::read(root.path().join("package-lock.json")).expect("lock");
        let manifest = PinnedAdapterManifest {
            package_json: Box::leak(package_json.into_boxed_slice()),
            package_lock: Box::leak(package_lock.into_boxed_slice()),
            embedded: None,
        };
        let error = verify_adapter_install(
            root.path(),
            "test-acp",
            Some((DISTRIBUTION, "sha512-other")),
            None,
            manifest,
        )
        .expect_err("integrity drift");
        assert_eq!(
            error,
            "adapter package integrity does not match Inline's pin"
        );
    }

    #[test]
    fn embedded_adapter_install_omits_optional_native_runtimes() {
        assert!(!npm_ci_arguments(false).contains(&"--omit=optional"));
        assert!(npm_ci_arguments(true).contains(&"--omit=optional"));
    }

    #[test]
    fn verifies_the_exact_embedded_amp_artifact_and_license() {
        let root = tempfile::tempdir().expect("tempdir");
        let manifest = pinned_adapter_manifest("amp").expect("Amp manifest");
        fs::write(root.path().join("package.json"), manifest.package_json).expect("manifest");
        fs::write(root.path().join("package-lock.json"), manifest.package_lock).expect("lock");
        write_embedded_artifact(root.path(), manifest).expect("embedded artifact");
        let support = inline_agent_driver_acp::provider_support("amp").expect("Amp support");
        let AcpDistribution::EmbeddedAdapter(distribution) = support.distribution else {
            panic!("expected embedded adapter");
        };

        let executable = verify_adapter_install(
            root.path(),
            support.executable,
            None,
            Some(distribution),
            manifest,
        )
        .expect("verified embedded adapter");
        assert_eq!(
            executable,
            fs::canonicalize(root.path().join("dist/index.js")).expect("executable")
        );

        fs::write(&executable, b"#!/usr/bin/env node\n// tampered\n").expect("tamper");
        let error = verify_adapter_install(
            root.path(),
            support.executable,
            None,
            Some(distribution),
            manifest,
        )
        .expect_err("tampered artifact");
        assert_eq!(
            error,
            "embedded adapter executable does not match Inline's pin"
        );
    }

    #[test]
    fn embedded_amp_rejects_an_installed_optional_native_runtime() {
        let root = tempfile::tempdir().expect("tempdir");
        let manifest = pinned_adapter_manifest("amp").expect("Amp manifest");
        fs::write(root.path().join("package.json"), manifest.package_json).expect("manifest");
        fs::write(root.path().join("package-lock.json"), manifest.package_lock).expect("lock");
        write_embedded_artifact(root.path(), manifest).expect("embedded artifact");
        fs::create_dir_all(root.path().join("node_modules/@ampcode/cli-darwin-arm64"))
            .expect("optional native runtime fixture");
        let support = inline_agent_driver_acp::provider_support("amp").expect("Amp support");
        let AcpDistribution::EmbeddedAdapter(distribution) = support.distribution else {
            panic!("expected embedded adapter");
        };

        let error = verify_adapter_install(
            root.path(),
            support.executable,
            None,
            Some(distribution),
            manifest,
        )
        .expect_err("optional native runtime must be rejected");
        assert_eq!(
            error,
            "embedded adapter install contains an optional bundled Amp runtime"
        );
    }
}
