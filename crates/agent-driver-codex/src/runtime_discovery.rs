//! Discovery and compatibility classification for local Codex runtimes.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use semver::Version;
use thiserror::Error;

use inline_agent_bridge::AgentDriver;

use crate::{CodexLaunchConfig, CodexVersionProbe, probe_codex_version, spawn_codex_driver};

const FIRST_STABLE_CATALOG_VERSION: (u64, u64, u64) = (0, 146, 0);
#[cfg(target_os = "macos")]
const OPENAI_TEAM_IDENTIFIER: &str = "2DC432GLL2";
const CHATGPT_CODEX_RELATIVE_PATH: &str = "ChatGPT.app/Contents/Resources/codex";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexRuntimeSource {
    Configured,
    Path,
    ChatGptApplication,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CodexRuntimeCapabilities {
    /// Stable request-only session catalog verified by fail-closed response
    /// decoding at runtime.
    pub stable_session_catalog: bool,
    /// Existing Inline turn driver remains exact-version certified until its
    /// full streamed-event fixture is advanced separately.
    pub existing_turn_driver: bool,
}

#[derive(Clone, PartialEq, Eq)]
pub struct CodexRuntime {
    executable: PathBuf,
    version: Version,
    source: CodexRuntimeSource,
    capabilities: CodexRuntimeCapabilities,
}

impl CodexRuntime {
    pub fn executable(&self) -> &Path {
        &self.executable
    }

    pub fn version(&self) -> &Version {
        &self.version
    }

    pub fn source(&self) -> CodexRuntimeSource {
        self.source
    }

    pub fn capabilities(&self) -> CodexRuntimeCapabilities {
        self.capabilities
    }
}

impl std::fmt::Debug for CodexRuntime {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexRuntime")
            .field("executable", &"<codex executable>")
            .field("version", &self.version)
            .field("source", &self.source)
            .field("capabilities", &self.capabilities)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct CodexRuntimeDiscoveryConfig {
    pub configured_executable: Option<PathBuf>,
    pub search_path: bool,
    pub search_chatgpt_app: bool,
}

impl Default for CodexRuntimeDiscoveryConfig {
    fn default() -> Self {
        Self {
            configured_executable: None,
            search_path: true,
            search_chatgpt_app: true,
        }
    }
}

impl std::fmt::Debug for CodexRuntimeDiscoveryConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexRuntimeDiscoveryConfig")
            .field(
                "configured_executable",
                &self
                    .configured_executable
                    .as_ref()
                    .map(|_| "<configured path>"),
            )
            .field("search_path", &self.search_path)
            .field("search_chatgpt_app", &self.search_chatgpt_app)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexRuntimeFailure {
    Unavailable,
    InvalidSignature,
    UnsupportedCatalogVersion,
    UnsupportedTurnDriverVersion,
    IncompatibleCatalog,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CodexRuntimeAttempt {
    pub source: CodexRuntimeSource,
    pub failure: CodexRuntimeFailure,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
#[error("no compatible Codex runtime was found")]
pub struct CodexRuntimeDiscoveryError {
    pub attempts: Vec<CodexRuntimeAttempt>,
}

/// Finds an already-authenticated local Codex runtime without owning login or
/// token persistence. Callers still use `account/read` to distinguish missing
/// authentication from an executable/setup failure.
pub async fn discover_codex_runtime(
    config: &CodexRuntimeDiscoveryConfig,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    discover_codex_runtime_with_requirement(config, CodexRuntimeRequirement::StableSessionCatalog)
        .await
}

/// Finds a runtime that satisfies both the additive session-catalog contract
/// and Inline's exact fixture certification for streamed turn execution.
pub async fn discover_codex_turn_runtime(
    config: &CodexRuntimeDiscoveryConfig,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    discover_codex_runtime_with_requirement(config, CodexRuntimeRequirement::ExistingTurnDriver)
        .await
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CodexRuntimeRequirement {
    StableSessionCatalog,
    ExistingTurnDriver,
}

async fn discover_codex_runtime_with_requirement(
    config: &CodexRuntimeDiscoveryConfig,
    requirement: CodexRuntimeRequirement,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    let mut attempts = Vec::new();
    let mut seen_executables = HashSet::new();
    for candidate in runtime_candidates(config) {
        let Some(executable) = resolve_executable_candidate(&candidate.executable) else {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::Unavailable,
            });
            continue;
        };
        if !seen_executables.insert(executable.clone()) {
            continue;
        }
        if candidate.verify_openai_signature
            && verify_chatgpt_codex_signature(&executable).await.is_err()
        {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::InvalidSignature,
            });
            continue;
        }

        let probe = match probe_candidate(&executable).await {
            Ok(probe) => probe,
            Err(_) => {
                attempts.push(CodexRuntimeAttempt {
                    source: candidate.source,
                    failure: CodexRuntimeFailure::Unavailable,
                });
                continue;
            }
        };
        let capabilities = runtime_capabilities(&probe.version);
        if !capabilities.stable_session_catalog {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::UnsupportedCatalogVersion,
            });
            continue;
        }
        if requirement == CodexRuntimeRequirement::ExistingTurnDriver
            && !capabilities.existing_turn_driver
        {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::UnsupportedTurnDriverVersion,
            });
            continue;
        }
        if probe_stable_session_catalog(&executable).await.is_err() {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::IncompatibleCatalog,
            });
            continue;
        }
        return Ok(CodexRuntime {
            executable: probe.executable,
            version: probe.version,
            source: candidate.source,
            capabilities,
        });
    }
    Err(CodexRuntimeDiscoveryError { attempts })
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RuntimeCandidate {
    executable: PathBuf,
    source: CodexRuntimeSource,
    verify_openai_signature: bool,
}

fn runtime_candidates(config: &CodexRuntimeDiscoveryConfig) -> Vec<RuntimeCandidate> {
    let mut candidates = Vec::new();
    if let Some(executable) = config.configured_executable.clone() {
        let verify_openai_signature = is_chatgpt_bundled_codex_path(&executable);
        candidates.push(RuntimeCandidate {
            executable,
            source: CodexRuntimeSource::Configured,
            verify_openai_signature,
        });
    }
    if config.search_path {
        candidates.push(RuntimeCandidate {
            executable: PathBuf::from("codex"),
            source: CodexRuntimeSource::Path,
            verify_openai_signature: false,
        });
    }
    if config.search_chatgpt_app {
        candidates.extend(chatgpt_runtime_candidates());
    }

    let mut seen = HashSet::new();
    candidates.retain(|candidate| seen.insert(candidate.executable.clone()));
    candidates
}

fn is_chatgpt_bundled_codex_path(executable: &Path) -> bool {
    executable.ends_with(CHATGPT_CODEX_RELATIVE_PATH)
}

fn resolve_executable_candidate(executable: &Path) -> Option<PathBuf> {
    if executable.components().count() == 1 {
        let search_path = std::env::var_os("PATH")?;
        return resolve_executable_in_paths(executable, std::env::split_paths(&search_path));
    }
    canonical_executable(executable)
}

fn resolve_executable_in_paths(
    executable: &Path,
    paths: impl IntoIterator<Item = PathBuf>,
) -> Option<PathBuf> {
    paths
        .into_iter()
        .find_map(|directory| canonical_executable(&directory.join(executable)))
}

fn canonical_executable(executable: &Path) -> Option<PathBuf> {
    let canonical = std::fs::canonicalize(executable).ok()?;
    canonical.is_file().then_some(canonical)
}

#[cfg(target_os = "macos")]
fn chatgpt_runtime_candidates() -> Vec<RuntimeCandidate> {
    let mut roots = vec![PathBuf::from("/Applications")];
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join("Applications"));
    }
    roots
        .into_iter()
        .map(|root| RuntimeCandidate {
            executable: root.join(CHATGPT_CODEX_RELATIVE_PATH),
            source: CodexRuntimeSource::ChatGptApplication,
            verify_openai_signature: true,
        })
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn chatgpt_runtime_candidates() -> Vec<RuntimeCandidate> {
    Vec::new()
}

async fn probe_candidate(executable: &Path) -> Result<CodexVersionProbe, ()> {
    let config = CodexLaunchConfig {
        executable: executable.to_owned(),
        transport: crate::CodexAppServerTransport::PrivateStdio,
        version_policy: crate::CodexVersionPolicy::Any,
        ..CodexLaunchConfig::default()
    };
    probe_codex_version(&config).await.map_err(|_| ())
}

async fn probe_stable_session_catalog(executable: &Path) -> Result<(), ()> {
    use std::time::Duration;

    let config = CodexLaunchConfig {
        executable: executable.to_owned(),
        transport: crate::CodexAppServerTransport::PrivateStdio,
        version_policy: crate::CodexVersionPolicy::Any,
        ..CodexLaunchConfig::default()
    };
    let spawned = tokio::time::timeout(
        Duration::from_secs(15),
        spawn_codex_driver(config, env!("CARGO_PKG_VERSION")),
    )
    .await
    .map_err(|_| ())?
    .map_err(|_| ())?;
    let contract = tokio::time::timeout(
        Duration::from_secs(15),
        spawned.driver.verify_session_catalog_contract(),
    )
    .await
    .map_err(|_| ());
    let shutdown = spawned.driver.shutdown().await;
    match (contract, shutdown) {
        (Ok(Ok(())), Ok(())) => Ok(()),
        _ => Err(()),
    }
}

fn runtime_capabilities(version: &Version) -> CodexRuntimeCapabilities {
    let minimum = Version::new(
        FIRST_STABLE_CATALOG_VERSION.0,
        FIRST_STABLE_CATALOG_VERSION.1,
        FIRST_STABLE_CATALOG_VERSION.2,
    );
    CodexRuntimeCapabilities {
        stable_session_catalog: version >= &minimum && version.major == 0,
        existing_turn_driver: crate::is_certified_codex_version(version),
    }
}

#[cfg(target_os = "macos")]
async fn verify_chatgpt_codex_signature(executable: &Path) -> Result<(), ()> {
    use std::process::Stdio;
    use std::time::Duration;

    use tokio::process::Command;
    use tokio::time::timeout;

    if !executable.is_file() {
        return Err(());
    }
    let verified = timeout(
        Duration::from_secs(5),
        Command::new("/usr/bin/codesign")
            .args(["--verify", "--strict", "--verbose=2"])
            .arg(format!(
                "-R=anchor apple generic and identifier \"codex\" and \
                 certificate leaf[subject.OU] = \"{OPENAI_TEAM_IDENTIFIER}\""
            ))
            .arg(executable)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status(),
    )
    .await
    .map_err(|_| ())?
    .map_err(|_| ())?;
    if !verified.success() {
        return Err(());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
async fn verify_chatgpt_codex_signature(_executable: &Path) -> Result<(), ()> {
    Err(())
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn catalog_compatibility_is_additive_but_turn_driver_requires_a_fixture() {
        assert_eq!(
            runtime_capabilities(&Version::new(0, 145, 0)),
            CodexRuntimeCapabilities::default()
        );
        assert_eq!(
            runtime_capabilities(&Version::new(0, 146, 0)),
            CodexRuntimeCapabilities {
                stable_session_catalog: true,
                existing_turn_driver: true,
            }
        );
        assert_eq!(
            runtime_capabilities(&Version::parse("0.149.0-alpha.4.3").expect("version")),
            CodexRuntimeCapabilities {
                stable_session_catalog: true,
                existing_turn_driver: false,
            }
        );
        assert_eq!(
            runtime_capabilities(&crate::latest_certified_codex_version()),
            CodexRuntimeCapabilities {
                stable_session_catalog: true,
                existing_turn_driver: true,
            }
        );
        assert!(!runtime_capabilities(&Version::new(1, 0, 0)).stable_session_catalog);
    }

    #[test]
    fn discovery_order_prefers_configured_then_path_then_chatgpt() {
        let candidates = runtime_candidates(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(PathBuf::from("/custom/codex")),
            search_path: true,
            search_chatgpt_app: true,
        });
        assert_eq!(candidates[0].source, CodexRuntimeSource::Configured);
        assert_eq!(candidates[1].source, CodexRuntimeSource::Path);
        #[cfg(target_os = "macos")]
        assert_eq!(candidates[2].source, CodexRuntimeSource::ChatGptApplication);
    }

    #[test]
    fn configured_chatgpt_runtime_keeps_signature_verification() {
        let candidates = runtime_candidates(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(PathBuf::from(
                "/Applications/ChatGPT.app/Contents/Resources/codex",
            )),
            search_path: false,
            search_chatgpt_app: false,
        });
        assert_eq!(candidates.len(), 1);
        assert!(candidates[0].verify_openai_signature);

        let standalone = runtime_candidates(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(PathBuf::from("/opt/homebrew/bin/codex")),
            search_path: false,
            search_chatgpt_app: false,
        });
        assert!(!standalone[0].verify_openai_signature);
    }

    #[test]
    fn runtime_debug_never_exposes_executable_path() {
        let runtime = CodexRuntime {
            executable: PathBuf::from("/private/path/to/codex"),
            version: Version::new(0, 146, 0),
            source: CodexRuntimeSource::Configured,
            capabilities: runtime_capabilities(&Version::new(0, 146, 0)),
        };
        assert!(!format!("{runtime:?}").contains("/private/path"));
    }

    #[test]
    fn path_resolution_returns_a_stable_absolute_executable() {
        let directory = tempfile::tempdir().expect("temp directory");
        let executable = directory.path().join("codex-test-runtime");
        std::fs::write(&executable, b"test runtime").expect("test executable");

        let resolved = resolve_executable_in_paths(
            Path::new("codex-test-runtime"),
            [directory.path().to_owned()],
        )
        .expect("resolved executable");
        assert!(resolved.is_absolute());
        assert_eq!(
            resolved,
            std::fs::canonicalize(executable).expect("canonical")
        );
    }

    #[cfg(unix)]
    fn fake_codex_runtime(catalog_response: &str) -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().expect("temp directory");
        let executable = directory.path().join("codex");
        let script = format!(
            "#!/bin/sh\n\
             if [ \"$1\" = \"--version\" ]; then\n\
               printf '%s\\n' 'codex-cli 0.146.0'\n\
               exit 0\n\
             fi\n\
             IFS= read -r initialize\n\
             printf '%s\\n' '{{\"id\":1,\"result\":{{\"userAgent\":\"codex_app_server/0.146.0\"}}}}'\n\
             IFS= read -r initialized\n\
             IFS= read -r catalog\n\
             printf '%s\\n' '{catalog_response}'\n\
             IFS= read -r loaded\n\
             printf '%s\\n' '{{\"id\":3,\"result\":{{\"data\":[],\"nextCursor\":null}}}}'\n\
             IFS= read -r read_thread\n\
             printf '%s\\n' '{{\"id\":4,\"error\":{{\"code\":-32000,\"message\":\"not found\"}}}}'\n\
             IFS= read -r rename_thread\n\
             printf '%s\\n' '{{\"id\":5,\"error\":{{\"code\":-32000,\"message\":\"not found\"}}}}'\n\
             IFS= read -r unsubscribe_thread\n\
             printf '%s\\n' '{{\"id\":6,\"result\":{{\"status\":\"notLoaded\"}}}}'\n\
             while IFS= read -r line; do :; done\n"
        );
        std::fs::write(&executable, script).expect("fake Codex runtime");
        let mut permissions = std::fs::metadata(&executable)
            .expect("fake runtime metadata")
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&executable, permissions).expect("executable permissions");
        (directory, executable)
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn discovery_advertises_catalog_only_after_live_schema_probe() {
        let (_compatible_directory, compatible) = fake_codex_runtime(
            "{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null,\"backwardsCursor\":null}}",
        );
        let runtime = discover_codex_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(compatible),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await
        .expect("compatible catalog");
        assert!(runtime.capabilities().stable_session_catalog);
        assert!(runtime.executable().is_absolute());

        let (_incompatible_directory, incompatible) =
            fake_codex_runtime("{\"id\":2,\"result\":{}}");
        let error = discover_codex_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(incompatible),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await
        .expect_err("incompatible catalog");
        assert_eq!(
            error.attempts,
            vec![CodexRuntimeAttempt {
                source: CodexRuntimeSource::Configured,
                failure: CodexRuntimeFailure::IncompatibleCatalog,
            }]
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "requires an installed, signed ChatGPT application"]
    async fn installed_chatgpt_codex_is_discoverable_for_the_stable_catalog() {
        let runtime = discover_codex_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: None,
            search_path: false,
            search_chatgpt_app: true,
        })
        .await
        .expect("signed ChatGPT Codex runtime");
        assert_eq!(runtime.source(), CodexRuntimeSource::ChatGptApplication);
        assert!(runtime.capabilities().stable_session_catalog);
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "requires an installed certified Codex or signed ChatGPT application"]
    async fn installed_turn_runtime_skips_catalog_only_candidates() {
        let runtime = discover_codex_turn_runtime(&CodexRuntimeDiscoveryConfig::default())
            .await
            .expect("fixture-certified Codex turn runtime");
        assert!(runtime.capabilities().existing_turn_driver);
    }
}
