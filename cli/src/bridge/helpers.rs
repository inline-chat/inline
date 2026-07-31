//! Small, side-effect-free bridge utilities and local filesystem helpers.

use super::*;

pub(super) fn safe_diagnostic(error: &str) -> String {
    let normalized = error.split_whitespace().collect::<Vec<_>>().join(" ");
    let lowered = normalized.to_ascii_lowercase();
    if [
        "authorization",
        "bearer ",
        "api_key",
        "api-key",
        "x-api-key",
        "access_token",
        "refresh_token",
        "token=",
        "token:",
        "password",
        "session=",
        "cookie",
        "secret",
    ]
    .iter()
    .any(|marker| lowered.contains(marker))
        || normalized.split_whitespace().any(looks_like_jwt)
    {
        return "[redacted provider diagnostic]".to_string();
    }
    truncate(&normalized, 512)
}

pub(super) fn safe_relative_path(path: &Path, workspace: &Path) -> Option<PathBuf> {
    let has_unsafe_component = |path: &Path| {
        path.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    };
    let relative = if path.is_absolute() {
        if path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return None;
        }
        path.strip_prefix(workspace)
            .ok()
            .filter(|relative| !has_unsafe_component(relative))?
            .to_path_buf()
    } else {
        (!has_unsafe_component(path)).then(|| path.to_path_buf())?
    };
    let candidate_path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        workspace.join(path)
    };
    let Ok(canonical_workspace) = fs::canonicalize(workspace) else {
        // Pure presentation tests may use a synthetic workspace. Runtime
        // workspaces are canonical existing directories before registration.
        return Some(relative);
    };
    if canonical_workspace != workspace {
        // Registered workspaces are stored as canonical absolute paths. If
        // that path now resolves somewhere else, its root was replaced or
        // redirected after registration and no local action is safe.
        return None;
    }
    if let Ok(canonical_path) = fs::canonicalize(&candidate_path) {
        return canonical_path
            .strip_prefix(&canonical_workspace)
            .ok()
            .filter(|relative| !has_unsafe_component(relative))
            .map(Path::to_path_buf);
    }

    // Changed/deleted paths may no longer exist. Prove that their nearest
    // existing ancestor still resolves inside the workspace so a symlinked
    // directory cannot turn a relative changed-file action into a host escape.
    let mut ancestor = candidate_path.parent();
    while let Some(candidate) = ancestor {
        if candidate.exists() {
            let canonical_ancestor = fs::canonicalize(candidate).ok()?;
            canonical_ancestor.strip_prefix(&canonical_workspace).ok()?;
            return Some(relative);
        }
        ancestor = candidate.parent();
    }
    None
}

pub(super) fn provider_restart_delay(consecutive_failures: u32) -> Duration {
    let exponent = consecutive_failures.saturating_sub(1).min(5);
    Duration::from_secs((1_u64 << exponent).min(30))
}

pub(super) fn looks_like_jwt(value: &str) -> bool {
    let value = value.trim_matches(|character: char| {
        matches!(character, '"' | '\'' | ',' | ';' | '(' | ')' | '[' | ']')
    });
    let segments = value.split('.').collect::<Vec<_>>();
    segments.len() == 3
        && segments.iter().all(|segment| {
            segment.len() >= 8
                && segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        })
}

pub(super) fn canonical_workspace(path: &Path) -> io::Result<PathBuf> {
    let path = fs::canonicalize(path)?;
    if !path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bridge folder must be a directory",
        ));
    }
    Ok(path)
}

pub(super) fn resolve_executable(executable: &Path) -> io::Result<PathBuf> {
    if executable.components().count() > 1 || executable.is_absolute() {
        return executable
            .is_file()
            .then(|| executable.to_path_buf())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!(
                        "provider executable does not exist: {}",
                        executable.display()
                    ),
                )
            });
    }

    let path = std::env::var_os("PATH")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "PATH is not available"))?;
    resolve_executable_in_search_path(executable, &path)
}

pub(super) fn resolve_executable_in_search_path(
    executable: &Path,
    search_path: &std::ffi::OsStr,
) -> io::Result<PathBuf> {
    if executable.components().count() > 1 || executable.is_absolute() {
        return resolve_executable(executable);
    }
    for directory in std::env::split_paths(search_path) {
        let candidate = directory.join(executable);
        if is_executable_file(&candidate) {
            return Ok(candidate);
        }
        #[cfg(windows)]
        {
            let candidate = directory.join(format!("{}.exe", executable.display()));
            if is_executable_file(&candidate) {
                return Ok(candidate);
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("could not find {} on PATH", executable.display()),
    ))
}

pub(super) fn find_named_executables(executable: &str, aliases: &[&str]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for name in std::iter::once(executable).chain(aliases.iter().copied()) {
        let Some(path) = env::var_os("PATH") else {
            continue;
        };
        for directory in env::split_paths(&path) {
            let candidate = directory.join(name);
            if is_executable_file(&candidate) && !found.contains(&candidate) {
                found.push(candidate);
            }
        }
    }
    found
}

pub(super) fn default_provider_path() -> String {
    env::var("PATH").unwrap_or_else(|_| {
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".to_string()
    })
}

pub(super) fn merged_provider_path(
    providers: &[ProviderInstallationConfig],
    current_path: &str,
) -> String {
    let mut seen = HashSet::new();
    let mut paths = Vec::new();
    for value in std::iter::once(current_path).chain(
        providers
            .iter()
            .map(|provider| provider.provider_path.as_str()),
    ) {
        for path in env::split_paths(value) {
            if seen.insert(path.clone()) {
                paths.push(path);
            }
        }
    }
    env::join_paths(paths)
        .ok()
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| current_path.to_string())
}

#[cfg(unix)]
pub(super) fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
pub(super) fn is_executable_file(path: &Path) -> bool {
    path.is_file()
}

pub(super) fn workspace_id(path: &Path) -> Result<WorkspaceId, Box<dyn std::error::Error>> {
    let digest = Sha256::digest(path.to_string_lossy().as_bytes());
    let mut value = String::from("workspace-");
    for byte in digest.iter().take(12) {
        value.push_str(&format!("{byte:02x}"));
    }
    Ok(WorkspaceId::new(value)?)
}

pub(super) fn read_optional_json<T: for<'de> Deserialize<'de>>(
    path: &Path,
) -> Result<Option<T>, Box<dyn std::error::Error>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(super) fn read_required_json<T: for<'de> Deserialize<'de>>(
    path: &Path,
) -> Result<T, Box<dyn std::error::Error>> {
    read_optional_json(path)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "bridge secrets are missing").into())
}

pub(super) fn acquire_instance_lock(path: &Path) -> io::Result<fs::File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(path)?;
    set_file_mode(path, 0o600)?;
    file.try_lock().map_err(|error| {
        io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("another agent bridge process is already using this account: {error}"),
        )
    })?;
    Ok(file)
}

pub(super) fn acquire_account_mutation_lock(paths: &BridgePaths) -> io::Result<fs::File> {
    let path = paths.root.join("account-mutation.lock");
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&path)?;
    set_file_mode(&path, 0o600)?;
    file.lock().map_err(|error| {
        io::Error::other(format!(
            "could not lock the bridge account for an atomic update: {error}"
        ))
    })?;
    Ok(file)
}

pub(super) fn write_private_json<T: Serialize>(
    path: &Path,
    value: &T,
) -> Result<(), Box<dyn std::error::Error>> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "bridge path has no parent"))?;
    ensure_private_dir(parent)?;
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(value)?;
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    set_file_mode(&temporary, 0o600)?;
    fs::rename(&temporary, path)?;
    set_file_mode(path, 0o600)?;
    Ok(())
}

pub(super) fn ensure_private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    set_dir_mode(path, 0o700)
}

#[cfg(unix)]
pub(super) fn set_file_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
pub(super) fn set_file_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
pub(super) fn set_dir_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
pub(super) fn set_dir_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

pub(super) fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub(super) fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub(super) fn interaction_random_id(kind: &str, token: &str) -> RandomId {
    let mut digest = Sha256::new();
    digest.update(b"inline-agent-bridge-interaction-v1");
    digest.update([0]);
    digest.update(kind.as_bytes());
    digest.update([0]);
    digest.update(token.as_bytes());
    let bytes: [u8; 8] = digest.finalize()[..8]
        .try_into()
        .expect("SHA-256 prefix has a fixed width");
    let value = (u64::from_be_bytes(bytes) & i64::MAX as u64).max(1) as i64;
    RandomId::new(value)
}

pub(super) fn provider_bot_username(
    provider_id: &str,
    owner_user_id: i64,
    host_installation_id: &str,
) -> String {
    format!(
        "inline_{provider_id}_{owner_user_id}_{}_bot",
        host_identity_suffix(host_installation_id)
    )
}

pub(super) fn provider_installation_id(provider_id: &str, host_installation_id: &str) -> String {
    format!(
        "{provider_id}-{}",
        host_identity_suffix(host_installation_id)
    )
}

fn host_identity_suffix(host_installation_id: &str) -> String {
    let digest = Sha256::digest(host_installation_id.as_bytes());
    digest[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn generate_control_token() -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let mut token = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        token.push_str(&format!("{byte:02x}"));
    }
    token
}

pub(super) fn generate_host_installation_id() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    let mut value = String::from("host-");
    for byte in bytes {
        value.push_str(&format!("{byte:02x}"));
    }
    value
}

pub(super) fn local_host_label() -> String {
    #[cfg(target_os = "macos")]
    let candidates: &[(&str, &[&str])] =
        &[("scutil", &["--get", "ComputerName"]), ("hostname", &[])];
    #[cfg(not(target_os = "macos"))]
    let candidates: &[(&str, &[&str])] = &[("hostname", &[])];
    for (program, arguments) in candidates {
        if let Ok(output) = Command::new(program).args(*arguments).output()
            && output.status.success()
            && let Ok(value) = String::from_utf8(output.stdout)
        {
            let value: String = value
                .trim()
                .chars()
                .filter(|character| !character.is_control())
                .take(80)
                .collect();
            if !value.is_empty() {
                return value;
            }
        }
    }
    if cfg!(target_os = "macos") {
        "this Mac".to_string()
    } else {
        "this computer".to_string()
    }
}

pub(super) fn private_chat_id(
    chat: &serde_json::Value,
    dialog: &serde_json::Value,
) -> io::Result<i64> {
    [
        chat.get("id"),
        chat.get("chatId"),
        chat.get("chat_id"),
        dialog.get("chatId"),
        dialog.get("chat_id"),
    ]
    .into_iter()
    .flatten()
    .find_map(|value| {
        value
            .as_i64()
            .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
    })
    .filter(|chat_id| *chat_id > 0)
    .ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "createPrivateChat returned no valid chat id",
        )
    })
}

pub(super) fn truncate(value: &str, maximum: usize) -> String {
    if value.len() <= maximum {
        return value.to_string();
    }
    let mut boundary = maximum.saturating_sub('…'.len_utf8());
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    format!("{}…", &value[..boundary])
}

pub(super) fn truncate_utf16(value: &str, maximum: usize) -> String {
    if value.encode_utf16().count() <= maximum {
        return value.to_string();
    }
    let content_limit = maximum.saturating_sub(1);
    let mut output = String::new();
    let mut units = 0;
    for character in value.chars() {
        let character_units = character.len_utf16();
        if units + character_units > content_limit {
            break;
        }
        output.push(character);
        units += character_units;
    }
    output.push('…');
    output
}
