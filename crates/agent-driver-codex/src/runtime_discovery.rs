//! Discovery and compatibility classification for local Codex runtimes.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use semver::Version;

use crate::{CodexLaunchConfig, CodexVersionProbe, probe_codex_version};

const FIRST_STABLE_CATALOG_VERSION: (u64, u64, u64) = (0, 146, 0);
#[cfg(target_os = "macos")]
const OPENAI_TEAM_IDENTIFIER: &str = "2DC432GLL2";
// Leave headroom inside the 30-second provider probe while tolerating transient
// security-service contention. Verification still fails closed on timeout.
#[cfg(target_os = "macos")]
const OPENAI_SIGNATURE_VERIFICATION_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(15);
// Current bundles first, then the layout older ChatGPT releases shipped.
const CHATGPT_CODEX_RELATIVE_PATHS: [&str; 2] = [
    "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "ChatGPT.app/Contents/Resources/codex",
];
// The bundle's `entrypoint` is an unsigned script that only execs the signed
// binary, so it can't pass signature verification and is never launched itself.
const CHATGPT_CODEX_WRAPPER_RELATIVE_PATH: &str =
    "ChatGPT.app/Contents/Resources/codex-cli/bin/codex";
const CHATGPT_CODEX_WRAPPER_TARGET: &str = "CodexCLI.app/Contents/MacOS/codex";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexRuntimeSource {
    Configured,
    Path,
    ChatGptApplication,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CodexRuntimeCapabilities {
    /// Version is eligible for the catalog. The owned app-server must still
    /// pass its read-only method/response check after launch.
    pub stable_session_catalog: bool,
    /// Version is eligible for the turn driver. Discovery does not execute
    /// mutations; each real operation validates its response and fails closed.
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexRuntimeAttempt {
    pub source: CodexRuntimeSource,
    pub failure: CodexRuntimeFailure,
    pub detail: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexRuntimeDiscoveryError {
    pub attempts: Vec<CodexRuntimeAttempt>,
}

impl std::fmt::Display for CodexRuntimeDiscoveryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no compatible Codex runtime was found")?;
        for attempt in self.attempts.iter().take(12) {
            write!(f, "; {:?}: {}", attempt.source, attempt.detail)?;
        }
        if self.attempts.len() > 12 {
            write!(
                f,
                "; {} more attempts; {}",
                self.attempts.len() - 12,
                self.attempts.last().unwrap().detail
            )?;
        }
        Ok(())
    }
}
impl std::error::Error for CodexRuntimeDiscoveryError {}

fn safe_probe_detail(value: &str) -> String {
    inline_agent_bridge::sanitize_visible_transcript(value)
        .unwrap_or_default()
        .chars()
        .take(600)
        .collect()
}

/// Uses the host's discovery directories so installation detection and setup
/// agree even when the process has a sparse PATH.
pub async fn discover_codex_turn_runtime_in_paths(
    config: &CodexRuntimeDiscoveryConfig,
    paths: impl IntoIterator<Item = PathBuf>,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    discover_candidates(runtime_candidates_in_paths(config, paths)).await
}

/// Finds an already-authenticated local Codex runtime without owning login or
/// token persistence. Callers still use `account/read` to distinguish missing
/// authentication from an executable/setup failure.
pub async fn discover_codex_runtime(
    config: &CodexRuntimeDiscoveryConfig,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    discover_candidates(runtime_candidates(config)).await
}

/// Finds a runtime that satisfies Inline's additive app-server contract.
pub async fn discover_codex_turn_runtime(
    config: &CodexRuntimeDiscoveryConfig,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    discover_candidates(runtime_candidates(config)).await
}

async fn discover_candidates(
    candidates: Vec<RuntimeCandidate>,
) -> Result<CodexRuntime, CodexRuntimeDiscoveryError> {
    let mut attempts = Vec::new();
    let started = std::time::Instant::now();
    let mut seen_executables = HashSet::new();
    for candidate in candidates {
        // Do not multiply per-probe deadlines across an arbitrarily long PATH.
        // Finish/clean up the current bounded probe before stopping discovery.
        if attempts.len() >= 16 || started.elapsed() >= std::time::Duration::from_secs(60) {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::Unavailable,
                detail: "runtime search budget exhausted; remove stale Codex installations from PATH and retry".into(),
            });
            break;
        }
        let Some(executable) = resolve_executable_candidate(&candidate.executable) else {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::Unavailable,
                detail: "executable is missing or is not executable".into(),
            });
            continue;
        };
        if !seen_executables.insert(executable.clone()) {
            continue;
        }
        if (candidate.verify_openai_signature || is_chatgpt_bundled_codex_path(&executable))
            && let Err(error) = verify_chatgpt_codex_signature(&executable).await
        {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::InvalidSignature,
                detail: safe_probe_detail(&error),
            });
            continue;
        }

        let probe = match probe_candidate(&executable).await {
            Ok(probe) => probe,
            Err(error) => {
                attempts.push(CodexRuntimeAttempt {
                    source: candidate.source,
                    failure: CodexRuntimeFailure::Unavailable,
                    detail: safe_probe_detail(&error),
                });
                continue;
            }
        };
        let capabilities = runtime_capabilities(&probe.version);
        log::debug!(
            "Codex runtime probe source={:?} version={} version_compatible={}",
            candidate.source,
            probe.version,
            capabilities.existing_turn_driver
        );
        if !capabilities.stable_session_catalog {
            attempts.push(CodexRuntimeAttempt {
                source: candidate.source,
                failure: CodexRuntimeFailure::UnsupportedCatalogVersion,
                detail: format!(
                    "Codex {} is too old for the required session API (minimum 0.146.0)",
                    probe.version
                ),
            });
            continue;
        }
        // Discovery verifies executable identity, provenance, and the minimum
        // protocol generation only. The selected long-lived app-server performs
        // the read-only shape probe on its own connection during launch. This
        // avoids starting a throwaway app-server that scans or contends with the
        // user's active Codex state before the real bridge process starts.
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
    let path = std::env::var_os("PATH").unwrap_or_default();
    runtime_candidates_in_paths(config, std::env::split_paths(&path))
}

fn runtime_candidates_in_paths(
    config: &CodexRuntimeDiscoveryConfig,
    paths: impl IntoIterator<Item = PathBuf>,
) -> Vec<RuntimeCandidate> {
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
        candidates.extend(
            paths
                .into_iter()
                .filter(|directory| directory.is_absolute())
                .map(|directory| directory.join("codex"))
                .filter(|executable| executable.is_file())
                .map(|executable| RuntimeCandidate {
                    executable,
                    source: CodexRuntimeSource::Path,
                    verify_openai_signature: false,
                }),
        );
    }
    if config.search_chatgpt_app {
        candidates.extend(chatgpt_runtime_candidates());
    }

    let mut seen = HashSet::new();
    candidates.retain(|candidate| seen.insert(candidate.executable.clone()));
    candidates
}

fn is_chatgpt_bundled_codex_path(executable: &Path) -> bool {
    executable.ends_with(CHATGPT_CODEX_WRAPPER_RELATIVE_PATH)
        || CHATGPT_CODEX_RELATIVE_PATHS
            .iter()
            .any(|relative| executable.ends_with(relative))
}

/// Codex executables a ChatGPT application under `applications_directory` may
/// provide, most recent layout first. Callers that run one still need the
/// signature check `discover_codex_turn_runtime` performs.
pub fn chatgpt_codex_executables_in(applications_directory: &Path) -> Vec<PathBuf> {
    CHATGPT_CODEX_RELATIVE_PATHS
        .iter()
        .map(|relative| applications_directory.join(relative))
        .collect()
}

/// The current bundle's executable for a saved path to the layout older ChatGPT
/// releases shipped, once an app update has removed it. Stays inside the same
/// application, and launch still verifies the signature of the path returned.
pub fn moved_chatgpt_codex_executable(configured: &Path) -> Option<PathBuf> {
    let [current, legacy] = CHATGPT_CODEX_RELATIVE_PATHS;
    if !configured.ends_with(legacy) || configured.exists() {
        return None;
    }
    let applications_directory = configured
        .ancestors()
        .nth(Path::new(legacy).iter().count())?;
    let executable = applications_directory.join(current);
    executable.is_file().then_some(executable)
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
    let mut canonical = std::fs::canonicalize(executable).ok()?;
    // Also covers a PATH symlink to the wrapper, which canonicalizes to it.
    if canonical.ends_with(CHATGPT_CODEX_WRAPPER_RELATIVE_PATH) {
        let codex_cli = canonical.parent()?.parent()?;
        canonical = std::fs::canonicalize(codex_cli.join(CHATGPT_CODEX_WRAPPER_TARGET)).ok()?;
    }
    let metadata = canonical.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o111 == 0 {
            return None;
        }
    }
    Some(canonical)
}

#[cfg(target_os = "macos")]
fn chatgpt_runtime_candidates() -> Vec<RuntimeCandidate> {
    let mut roots = vec![PathBuf::from("/Applications")];
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join("Applications"));
    }
    roots
        .iter()
        .flat_map(|root| chatgpt_codex_executables_in(root))
        .map(|executable| RuntimeCandidate {
            executable,
            source: CodexRuntimeSource::ChatGptApplication,
            verify_openai_signature: true,
        })
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn chatgpt_runtime_candidates() -> Vec<RuntimeCandidate> {
    Vec::new()
}

async fn probe_candidate(executable: &Path) -> Result<CodexVersionProbe, String> {
    let config = CodexLaunchConfig {
        executable: executable.to_owned(),
        transport: crate::CodexAppServerTransport::PrivateStdio,
        version_policy: crate::CodexVersionPolicy::Any,
        ..CodexLaunchConfig::default()
    };
    probe_codex_version(&config)
        .await
        .map_err(|error| error.to_string())
}

fn runtime_capabilities(version: &Version) -> CodexRuntimeCapabilities {
    let minimum = Version::new(
        FIRST_STABLE_CATALOG_VERSION.0,
        FIRST_STABLE_CATALOG_VERSION.1,
        FIRST_STABLE_CATALOG_VERSION.2,
    );
    CodexRuntimeCapabilities {
        stable_session_catalog: version >= &minimum,
        existing_turn_driver: version >= &minimum,
    }
}

#[cfg(target_os = "macos")]
async fn verify_chatgpt_codex_signature(executable: &Path) -> Result<(), String> {
    use std::process::Stdio;

    use tokio::process::Command;
    use tokio::time::timeout;

    if !executable.is_file() {
        return Err("Codex executable is missing".into());
    }
    use tokio::io::AsyncReadExt;
    let mut child = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--verbose=2"])
        .arg(format!(
            "-R=anchor apple generic and identifier \"codex\" and \
             certificate leaf[subject.OU] = \"{OPENAI_TEAM_IDENTIFIER}\""
        ))
        .arg(executable)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("could not launch codesign: {error}"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| "codesign stderr unavailable".to_string())?;
    let (diagnostic, verified) = timeout(OPENAI_SIGNATURE_VERIFICATION_TIMEOUT, async {
        tokio::join!(
            async {
                let mut tail = Vec::new();
                let mut buffer = [0; 2048];
                loop {
                    let count = stderr.read(&mut buffer).await?;
                    if count == 0 {
                        break;
                    }
                    tail.extend_from_slice(&buffer[..count]);
                    if tail.len() > 4096 {
                        tail.drain(..tail.len() - 4096);
                    }
                }
                Ok::<_, std::io::Error>(tail)
            },
            child.wait()
        )
    })
    .await
    .map_err(|_| "OpenAI signature verification timed out".to_string())?;
    let verified = verified.map_err(|error| format!("could not wait for codesign: {error}"))?;
    if !verified.success() {
        let detail = diagnostic
            .map(|bytes| safe_probe_detail(&String::from_utf8_lossy(&bytes)))
            .unwrap_or_default();
        return Err(format!(
            "OpenAI signature verification failed (codesign exit {:?}): {detail}",
            verified.code()
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
async fn verify_chatgpt_codex_signature(_executable: &Path) -> Result<(), String> {
    Err("OpenAI application signature verification is only supported on macOS".into())
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn runtime_compatibility_accepts_the_minimum_and_all_future_versions() {
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
                existing_turn_driver: true,
            }
        );
        assert_eq!(
            runtime_capabilities(&Version::parse("0.151.0-alpha.7.2").expect("future prerelease")),
            CodexRuntimeCapabilities {
                stable_session_catalog: true,
                existing_turn_driver: true,
            }
        );
        assert_eq!(
            runtime_capabilities(&Version::new(1, 0, 0)),
            CodexRuntimeCapabilities {
                stable_session_catalog: true,
                existing_turn_driver: true,
            }
        );
    }

    #[test]
    fn discovery_order_prefers_configured_then_path_then_chatgpt() {
        let candidates = runtime_candidates(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(PathBuf::from("/custom/codex")),
            search_path: true,
            search_chatgpt_app: true,
        });
        assert_eq!(candidates[0].source, CodexRuntimeSource::Configured);
        #[cfg(target_os = "macos")]
        assert_eq!(
            candidates.last().unwrap().source,
            CodexRuntimeSource::ChatGptApplication
        );
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

        for bundled in [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ] {
            let candidates = runtime_candidates(&CodexRuntimeDiscoveryConfig {
                configured_executable: Some(PathBuf::from(bundled)),
                search_path: false,
                search_chatgpt_app: false,
            });
            assert!(candidates[0].verify_openai_signature, "{bundled}");
        }
    }

    #[test]
    fn chatgpt_candidates_prefer_the_current_bundle_layout() {
        assert_eq!(
            chatgpt_codex_executables_in(Path::new("/Applications")),
            [
                PathBuf::from(
                    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
                ),
                PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"),
            ]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn chatgpt_app_search_covers_both_layouts_with_signature_verification() {
        let candidates = runtime_candidates(&CodexRuntimeDiscoveryConfig {
            configured_executable: None,
            search_path: false,
            search_chatgpt_app: true,
        });
        for executable in chatgpt_codex_executables_in(Path::new("/Applications")) {
            let candidate = candidates
                .iter()
                .find(|candidate| candidate.executable == executable)
                .expect("ChatGPT layout is searched");
            assert_eq!(candidate.source, CodexRuntimeSource::ChatGptApplication);
            assert!(candidate.verify_openai_signature);
        }
    }

    #[cfg(unix)]
    fn write_fake_bundled_file(root: &Path, relative: &str) -> PathBuf {
        let path = root.join(relative);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("bundle directories");
        // Exits 99 so a probe that skipped signature verification cannot pass.
        std::fs::write(&path, "#!/bin/sh\nexit 99\n").expect("fake bundled file");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .expect("executable permissions");
        path
    }

    #[cfg(unix)]
    #[test]
    fn saved_legacy_path_moves_to_the_current_bundle_in_the_same_application() {
        let [current, legacy] = CHATGPT_CODEX_RELATIVE_PATHS;
        let root = tempfile::tempdir().expect("application fixture");
        let saved = root.path().join(legacy);

        // Nothing to move to yet.
        assert_eq!(moved_chatgpt_codex_executable(&saved), None);

        let moved = write_fake_bundled_file(root.path(), current);
        assert_eq!(moved_chatgpt_codex_executable(&saved), Some(moved.clone()));
        assert!(is_chatgpt_bundled_codex_path(&moved));

        // A saved path that still exists is left alone, as is any other install.
        write_fake_bundled_file(root.path(), legacy);
        assert_eq!(moved_chatgpt_codex_executable(&saved), None);
        assert_eq!(
            moved_chatgpt_codex_executable(&root.path().join("homebrew/bin/codex")),
            None
        );
    }

    #[cfg(unix)]
    async fn discovery_failure(config: CodexRuntimeDiscoveryConfig) -> CodexRuntimeFailure {
        discover_codex_runtime(&config)
            .await
            .expect_err("fake runtime must not be selected")
            .attempts[0]
            .failure
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unsigned_runtime_is_rejected_in_every_chatgpt_layout() {
        for relative in [
            "ChatGPT.app/Contents/Resources/codex",
            "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ] {
            let root = tempfile::tempdir().expect("application fixture");
            let executable = write_fake_bundled_file(root.path(), relative);
            let failure = discovery_failure(CodexRuntimeDiscoveryConfig {
                configured_executable: Some(executable),
                search_path: false,
                search_chatgpt_app: false,
            })
            .await;
            assert_eq!(failure, CodexRuntimeFailure::InvalidSignature, "{relative}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn chatgpt_wrapper_resolves_to_the_signed_binary_it_launches() {
        let root = tempfile::tempdir().expect("application fixture");
        let wrapper = write_fake_bundled_file(root.path(), CHATGPT_CODEX_WRAPPER_RELATIVE_PATH);
        let signed = write_fake_bundled_file(root.path(), CHATGPT_CODEX_RELATIVE_PATHS[0]);
        let signed = std::fs::canonicalize(signed).expect("canonical");

        assert_eq!(canonical_executable(&wrapper).as_ref(), Some(&signed));

        let path_directory = tempfile::tempdir().expect("PATH fixture");
        let symlink = path_directory.path().join("codex");
        std::os::unix::fs::symlink(&wrapper, &symlink).expect("PATH symlink");
        assert_eq!(canonical_executable(&symlink), Some(signed));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn path_symlink_to_chatgpt_wrapper_keeps_signature_verification() {
        let root = tempfile::tempdir().expect("application fixture");
        let wrapper = write_fake_bundled_file(root.path(), CHATGPT_CODEX_WRAPPER_RELATIVE_PATH);
        write_fake_bundled_file(root.path(), CHATGPT_CODEX_RELATIVE_PATHS[0]);
        let path_directory = tempfile::tempdir().expect("PATH fixture");
        std::os::unix::fs::symlink(&wrapper, path_directory.path().join("codex"))
            .expect("PATH symlink");

        let error = discover_codex_turn_runtime_in_paths(
            &CodexRuntimeDiscoveryConfig {
                configured_executable: None,
                search_path: true,
                search_chatgpt_app: false,
            },
            [path_directory.path().to_owned()],
        )
        .await
        .expect_err("unsigned runtime must not be selected");
        assert_eq!(
            error.attempts[0].failure,
            CodexRuntimeFailure::InvalidSignature
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn chatgpt_wrapper_without_its_signed_binary_is_unavailable() {
        let root = tempfile::tempdir().expect("application fixture");
        let wrapper = write_fake_bundled_file(root.path(), CHATGPT_CODEX_WRAPPER_RELATIVE_PATH);
        let failure = discovery_failure(CodexRuntimeDiscoveryConfig {
            configured_executable: Some(wrapper),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await;
        assert_eq!(failure, CodexRuntimeFailure::Unavailable);
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
        #[cfg(unix)]
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();

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
    fn fake_codex_runtime(_catalog_response: &str) -> (tempfile::TempDir, PathBuf) {
        let directory = tempfile::tempdir().expect("temp directory");
        let executable = directory.path().join("codex");
        let script = "#!/bin/sh\n\
            if [ \"$1\" = \"--version\" ]; then\n\
              printf '%s\\n' 'codex-cli 0.146.0'\n\
              exit 0\n\
            fi\n\
            printf '%s\\n' 'unexpected app-server launch during discovery' >&2\n\
            exit 99\n";
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
    async fn discovery_tries_later_search_directories_after_old_and_non_executable_files() {
        let (old_dir, old) = fake_codex_runtime("{}");
        let script = std::fs::read_to_string(&old)
            .unwrap()
            .replace("0.146.0", "0.71.0");
        std::fs::write(&old, script).unwrap();
        let non_executable = tempfile::tempdir().unwrap();
        std::fs::write(non_executable.path().join("codex"), "not executable").unwrap();
        let (valid_dir, valid) = fake_codex_runtime(
            "{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null,\"backwardsCursor\":null}}",
        );
        let config = CodexRuntimeDiscoveryConfig {
            configured_executable: None,
            search_path: true,
            search_chatgpt_app: false,
        };
        let runtime = discover_codex_turn_runtime_in_paths(
            &config,
            [
                old_dir.path().to_owned(),
                non_executable.path().to_owned(),
                valid_dir.path().to_owned(),
            ],
        )
        .await
        .unwrap();
        assert_eq!(runtime.executable(), std::fs::canonicalize(valid).unwrap());
        let error = discover_codex_turn_runtime_in_paths(&config, [old_dir.path().to_owned()])
            .await
            .unwrap_err();
        assert!(error.to_string().contains("0.71.0"));
        assert!(!error.to_string().contains(&old.display().to_string()));
    }

    #[test]
    fn automatic_discovery_does_not_execute_relative_path_entries() {
        let candidates = runtime_candidates_in_paths(
            &CodexRuntimeDiscoveryConfig {
                configured_executable: None,
                search_path: true,
                search_chatgpt_app: false,
            },
            [PathBuf::new(), PathBuf::from("."), PathBuf::from("tools")],
        );
        assert!(candidates.is_empty());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn invalid_signature_preserves_bounded_codesign_detail() {
        let (_directory, executable) = fake_codex_runtime("{}");
        let error = verify_chatgpt_codex_signature(&executable)
            .await
            .unwrap_err();
        assert!(error.contains("codesign exit"));
        assert!(error.contains("not signed") || error.contains("signature"));
        assert!(!error.contains(executable.to_str().unwrap()));
        assert!(error.len() < 1_000);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn discovery_defers_live_shape_validation_to_the_owned_app_server() {
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

        let (_different_shape_directory, different_shape) =
            fake_codex_runtime("{\"id\":2,\"result\":{}}");
        let runtime = discover_codex_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(different_shape),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await
        .expect("discovery does not launch a throwaway app-server");
        assert!(runtime.capabilities().stable_session_catalog);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn future_versions_are_selected_for_live_contract_negotiation() {
        let (_directory, executable) = fake_codex_runtime(
            "{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":null,\"backwardsCursor\":null}}",
        );
        let script = std::fs::read_to_string(&executable)
            .expect("future runtime script")
            .replace("0.146.0", "1.7.3");
        std::fs::write(&executable, script).expect("future runtime script");

        let runtime = discover_codex_turn_runtime(&CodexRuntimeDiscoveryConfig {
            configured_executable: Some(executable),
            search_path: false,
            search_chatgpt_app: false,
        })
        .await
        .expect("future capability-compatible runtime");

        assert_eq!(runtime.version(), &Version::new(1, 7, 3));
        assert!(runtime.capabilities().stable_session_catalog);
        assert!(runtime.capabilities().existing_turn_driver);
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
    #[ignore = "requires an installed compatible Codex or signed ChatGPT application"]
    async fn installed_turn_runtime_accepts_a_capability_compatible_candidate() {
        let runtime = discover_codex_turn_runtime(&CodexRuntimeDiscoveryConfig::default())
            .await
            .expect("capability-compatible Codex turn runtime");
        assert!(runtime.capabilities().existing_turn_driver);
    }
}
