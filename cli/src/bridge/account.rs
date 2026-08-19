//! Account-scoped bridge manifests, persistence, and validation.

use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DevBridgeConfig {
    pub(super) version: u32,
    pub(super) installation_id: String,
    pub(super) owner_user_id: i64,
    pub(super) bot_user_id: i64,
    pub(super) bot_username: String,
    pub(super) dm_chat_id: Option<i64>,
    pub(super) workspace: PathBuf,
    pub(super) greeting_sent: bool,
    #[serde(default)]
    pub(super) accept_messages_after: i64,
    #[serde(default)]
    pub(super) initial_cursor_seeded: bool,
    #[serde(default)]
    pub(super) display_name: String,
    #[serde(default)]
    pub(super) api_base_url: String,
    #[serde(default)]
    pub(super) realtime_url: String,
    #[serde(default)]
    pub(super) codex_executable: PathBuf,
    #[serde(default)]
    pub(super) provider_path: String,
    #[serde(default)]
    pub(super) service_label: String,
    #[serde(default)]
    pub(super) service_binary: PathBuf,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct DevBridgeSecrets {
    pub(super) bot_user_id: i64,
    pub(super) bot_token: String,
    #[serde(default)]
    pub(super) control_token: String,
}

impl std::fmt::Debug for DevBridgeSecrets {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DevBridgeSecrets")
            .field("bot_user_id", &self.bot_user_id)
            .field("bot_token", &"<redacted>")
            .field("control_token", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AccountBridgeConfig {
    pub(super) version: u32,
    pub(super) owner_user_id: i64,
    #[serde(default)]
    pub(super) host_installation_id: String,
    #[serde(default)]
    pub(super) host_label: String,
    pub(super) api_base_url: String,
    pub(super) realtime_url: String,
    pub(super) service_label: String,
    pub(super) service_binary: PathBuf,
    #[serde(default)]
    pub(super) provider_path: String,
    #[serde(default)]
    pub(super) superseded_service_labels: Vec<String>,
    #[serde(default)]
    pub(super) operator_user_ids: Vec<i64>,
    #[serde(default)]
    pub(super) owner_control_cursor_seeded: bool,
    pub(super) providers: Vec<ProviderInstallationConfig>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderInstallationConfig {
    pub(super) installation_id: String,
    pub(super) provider_id: String,
    pub(super) bot_user_id: i64,
    pub(super) bot_username: String,
    pub(super) dm_chat_id: Option<i64>,
    pub(super) workspace: PathBuf,
    pub(super) greeting_sent: bool,
    #[serde(default)]
    pub(super) accept_messages_after: i64,
    #[serde(default)]
    pub(super) initial_cursor_seeded: bool,
    #[serde(default)]
    pub(super) display_name: String,
    #[serde(default)]
    pub(super) managed_avatar_digest: Option<String>,
    #[serde(default)]
    pub(super) managed_avatar_file_unique_id: Option<String>,
    pub(super) executable: PathBuf,
    #[serde(default)]
    pub(super) provider_runtime: Option<PathBuf>,
    #[serde(default)]
    pub(super) provider_path: String,
    pub(super) state_dir: PathBuf,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AccountBridgeSecrets {
    pub(super) version: u32,
    pub(super) owner_user_id: i64,
    pub(super) control_token: String,
    #[serde(default)]
    pub(super) owner_auth: Option<AuthCredential>,
    /// Legacy v1 bearer owner authority. New records leave this empty and use `owner_auth`.
    #[serde(default)]
    pub(super) owner_token: String,
    pub(super) providers: Vec<ProviderCredentials>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderCredentials {
    pub(super) installation_id: String,
    pub(super) bot_user_id: i64,
    pub(super) bot_token: String,
}

impl std::fmt::Debug for AccountBridgeSecrets {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountBridgeSecrets")
            .field("version", &self.version)
            .field("owner_user_id", &self.owner_user_id)
            .field("control_token", &"<redacted>")
            .field(
                "owner_auth",
                &self.owner_auth.as_ref().map(|_| "<redacted>"),
            )
            .field("owner_token", &"<redacted>")
            .field("providers", &self.providers)
            .finish()
    }
}

impl std::fmt::Debug for ProviderCredentials {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProviderCredentials")
            .field("installation_id", &self.installation_id)
            .field("bot_user_id", &self.bot_user_id)
            .field("bot_token", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug)]
pub(super) struct BridgePaths {
    pub(super) root: PathBuf,
    pub(super) config: PathBuf,
    pub(super) secrets: PathBuf,
    pub(super) instance_lock: PathBuf,
    pub(super) control_socket: PathBuf,
    pub(super) owner_client_db: PathBuf,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(super) logs_dir: PathBuf,
    pub(super) stdout_log: PathBuf,
    pub(super) stderr_log: PathBuf,
    pub(super) installed_binary: PathBuf,
}

impl BridgePaths {
    pub(super) fn for_owner(config: &Config, owner_user_id: i64) -> Self {
        let root = config
            .data_dir
            .join("bridge")
            .join("accounts")
            .join(owner_user_id.to_string());
        let installed_binary = root.join("bin").join("inline");
        Self::from_root(root, installed_binary)
    }

    pub(super) fn legacy(config: &Config) -> Self {
        let root = config.data_dir.join("bridge").join(INSTALLATION_ID);
        Self::from_root(root, config.data_dir.join("bin").join("inline"))
    }

    pub(super) fn from_root(root: PathBuf, installed_binary: PathBuf) -> Self {
        Self {
            config: root.join("config.json"),
            secrets: root.join("secrets.json"),
            instance_lock: root.join("bridge.lock"),
            control_socket: root.join("control.sock"),
            owner_client_db: root.join("owner-client.sqlite"),
            logs_dir: root.join("logs"),
            stdout_log: root.join("logs").join("bridge.log"),
            stderr_log: root.join("logs").join("bridge.error.log"),
            installed_binary,
            root,
        }
    }

    pub(super) fn for_config_path(path: &Path) -> io::Result<Self> {
        let root = path
            .parent()
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "bridge config has no parent")
            })?
            .to_path_buf();
        let installed_binary = root.join("bin").join("inline");
        Ok(Self {
            config: path.to_path_buf(),
            secrets: root.join("secrets.json"),
            instance_lock: root.join("bridge.lock"),
            control_socket: root.join("control.sock"),
            owner_client_db: root.join("owner-client.sqlite"),
            logs_dir: root.join("logs"),
            stdout_log: root.join("logs").join("bridge.log"),
            stderr_log: root.join("logs").join("bridge.error.log"),
            installed_binary,
            root,
        })
    }

    pub(super) fn provider_paths(
        &self,
        installation: &ProviderInstallationConfig,
    ) -> ProviderPaths {
        ProviderPaths {
            bridge_db: installation.state_dir.join("bridge.sqlite"),
            bot_client_db: installation.state_dir.join("bot-client.sqlite"),
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct ProviderPaths {
    pub(super) bridge_db: PathBuf,
    pub(super) bot_client_db: PathBuf,
}

#[derive(Debug)]

pub(super) struct LoadedAccount {
    pub(super) paths: BridgePaths,
    pub(super) account: AccountBridgeConfig,
    pub(super) secrets: AccountBridgeSecrets,
}

pub(super) fn load_installation(
    config: &Config,
) -> Result<LoadedAccount, Box<dyn std::error::Error>> {
    load_installed_account(config)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "agent bridge is not installed; run `inline setup codex` (or experimental `opencode|claude|amp`) first",
        )
        .into()
    })
}

pub(super) fn load_installed_account(
    config: &Config,
) -> Result<Option<LoadedAccount>, Box<dyn std::error::Error>> {
    if let Some(owner_user_id) = current_owner_user_id(config) {
        let paths = BridgePaths::for_owner(config, owner_user_id);
        if paths.config.is_file() {
            return load_account_at(paths).map(Some);
        }
        let legacy_paths = BridgePaths::legacy(config);
        if legacy_paths.config.is_file() {
            if configured_owner_user_id(&legacy_paths.config)? != owner_user_id {
                return Ok(None);
            }
            let loaded = load_account_at(legacy_paths)?;
            return Ok(Some(loaded));
        }
        return Ok(None);
    }

    let mut candidates = load_all_installed_accounts(config)?;
    if candidates.len() > 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "multiple Inline account bridge services are installed; log in to select the account to manage",
        )
        .into());
    }
    Ok(candidates.pop())
}

pub(super) fn load_all_installed_accounts(
    config: &Config,
) -> Result<Vec<LoadedAccount>, Box<dyn std::error::Error>> {
    let accounts_root = config.data_dir.join("bridge").join("accounts");
    let mut candidates = Vec::new();
    if accounts_root.is_dir() {
        for entry in fs::read_dir(&accounts_root)? {
            let entry = entry?;
            let paths =
                BridgePaths::from_root(entry.path(), entry.path().join("bin").join("inline"));
            if entry.file_type()?.is_dir() && paths.config.is_file() {
                candidates.push(load_account_at(paths)?);
            }
        }
    }
    let legacy_paths = BridgePaths::legacy(config);
    if legacy_paths.config.is_file() {
        let legacy = load_account_at(legacy_paths)?;
        if !candidates
            .iter()
            .any(|candidate| candidate.account.owner_user_id == legacy.account.owner_user_id)
        {
            candidates.push(legacy);
        }
    }
    Ok(candidates)
}

pub(super) fn load_account_at(
    paths: BridgePaths,
) -> Result<LoadedAccount, Box<dyn std::error::Error>> {
    let (account, secrets) = load_account_files(&paths)?;
    validate_account(&account, &secrets)?;
    Ok(LoadedAccount {
        paths,
        account,
        secrets,
    })
}

pub(super) fn configured_owner_user_id(path: &Path) -> Result<i64, Box<dyn std::error::Error>> {
    let value: serde_json::Value = read_required_json(path)?;
    value
        .get("ownerUserId")
        .and_then(serde_json::Value::as_i64)
        .filter(|owner_user_id| *owner_user_id > 0)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "bridge config has no valid owner user id",
            )
            .into()
        })
}

pub(super) fn current_owner_user_id(config: &Config) -> Option<i64> {
    LocalDb::new(config.state_path.clone(), config.api_base_url.clone())
        .load()
        .ok()
        .and_then(|state| state.current_user)
        .map(|user| user.id)
        .filter(|id| *id > 0)
}

pub(super) fn load_account_files(
    paths: &BridgePaths,
) -> Result<(AccountBridgeConfig, AccountBridgeSecrets), Box<dyn std::error::Error>> {
    let value: serde_json::Value = read_required_json(&paths.config)?;
    let version = value
        .get("version")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "bridge config has no version")
        })?;
    match version as u32 {
        ACCOUNT_CONFIG_VERSION => {
            let account: AccountBridgeConfig = serde_json::from_value(value)?;
            let secrets: AccountBridgeSecrets = read_required_json(&paths.secrets)?;
            validate_account_location(paths, &account)?;
            Ok((account, secrets))
        }
        LEGACY_CONFIG_VERSION => {
            let legacy: DevBridgeConfig = serde_json::from_value(value)?;
            let legacy_secrets: DevBridgeSecrets = read_required_json(&paths.secrets)?;
            let legacy_root = fs::canonicalize(&paths.root).unwrap_or_else(|_| paths.root.clone());
            account_from_legacy(legacy, legacy_secrets, &legacy_root)
        }
        version => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "bridge config version {version} is not supported (maximum {ACCOUNT_CONFIG_VERSION})"
            ),
        )
        .into()),
    }
}

pub(super) fn validate_account_location(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let account_scoped = paths
        .root
        .parent()
        .and_then(Path::file_name)
        .is_some_and(|name| name == "accounts");
    if account_scoped
        && (paths
            .root
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.parse::<i64>().ok())
            != Some(account.owner_user_id)
            || account.service_binary != paths.installed_binary)
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "bridge account directory or service binary does not match its owner identity",
        )
        .into());
    }
    if account_scoped {
        let provider_root = paths.root.join("providers");
        let bridge_root =
            paths.root.parent().and_then(Path::parent).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "invalid account root")
            })?;
        for provider in &account.providers {
            let legacy_state = bridge_root.join(&provider.installation_id);
            if !provider.state_dir.starts_with(&provider_root) && provider.state_dir != legacy_state
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "provider runtime state is outside its account namespace",
                )
                .into());
            }
        }
    }
    Ok(())
}

pub(super) fn account_from_legacy(
    legacy: DevBridgeConfig,
    legacy_secrets: DevBridgeSecrets,
    legacy_root: &Path,
) -> Result<(AccountBridgeConfig, AccountBridgeSecrets), Box<dyn std::error::Error>> {
    if legacy.version != LEGACY_CONFIG_VERSION || legacy.installation_id != INSTALLATION_ID {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "legacy bridge config is not a supported Codex v3 installation",
        )
        .into());
    }
    let provider = ProviderInstallationConfig {
        installation_id: legacy.installation_id,
        provider_id: PROVIDER_ID.to_string(),
        bot_user_id: legacy.bot_user_id,
        bot_username: legacy.bot_username,
        dm_chat_id: legacy.dm_chat_id,
        workspace: legacy.workspace,
        greeting_sent: legacy.greeting_sent,
        accept_messages_after: legacy.accept_messages_after,
        initial_cursor_seeded: legacy.initial_cursor_seeded,
        display_name: legacy.display_name,
        managed_avatar_digest: None,
        managed_avatar_file_unique_id: None,
        executable: legacy.codex_executable,
        provider_runtime: None,
        provider_path: legacy.provider_path.clone(),
        state_dir: legacy_root.to_path_buf(),
    };
    let account = AccountBridgeConfig {
        version: ACCOUNT_CONFIG_VERSION,
        owner_user_id: legacy.owner_user_id,
        host_installation_id: String::new(),
        host_label: String::new(),
        api_base_url: legacy.api_base_url,
        realtime_url: legacy.realtime_url,
        service_label: legacy.service_label,
        service_binary: legacy.service_binary,
        provider_path: legacy.provider_path,
        superseded_service_labels: Vec::new(),
        operator_user_ids: vec![legacy.owner_user_id],
        owner_control_cursor_seeded: false,
        providers: vec![provider],
    };
    let secrets = AccountBridgeSecrets {
        version: ACCOUNT_SECRETS_VERSION,
        owner_user_id: account.owner_user_id,
        control_token: legacy_secrets.control_token,
        owner_auth: None,
        owner_token: String::new(),
        providers: vec![ProviderCredentials {
            installation_id: INSTALLATION_ID.to_string(),
            bot_user_id: legacy_secrets.bot_user_id,
            bot_token: legacy_secrets.bot_token,
        }],
    };
    validate_account_for_setup(&account, &secrets)?;
    Ok((account, secrets))
}

pub(super) fn validate_account_for_setup(
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut repairable = secrets.clone();
    if repairable.control_token.trim().is_empty() {
        repairable.control_token = "pending-setup-repair".to_string();
    }
    if repairable.owner_auth.is_none() && repairable.owner_token.trim().is_empty() {
        repairable.owner_auth = Some(AuthCredential::AccessToken {
            token: AuthToken::try_new("pending-setup-repair")?,
        });
        repairable.version = ACCOUNT_SECRETS_VERSION;
    }
    for provider in &account.providers {
        match repairable
            .providers
            .iter_mut()
            .find(|credentials| credentials.installation_id == provider.installation_id)
        {
            Some(credentials)
                if credentials.bot_user_id == provider.bot_user_id
                    && credentials.bot_token.trim().is_empty() =>
            {
                credentials.bot_token = "pending-setup-repair".to_string();
            }
            None => repairable.providers.push(ProviderCredentials {
                installation_id: provider.installation_id.clone(),
                bot_user_id: provider.bot_user_id,
                bot_token: "pending-setup-repair".to_string(),
            }),
            Some(_) => {}
        }
    }
    validate_account(account, &repairable)
}

pub(super) fn validate_account(
    account: &AccountBridgeConfig,
    secrets: &AccountBridgeSecrets,
) -> Result<(), Box<dyn std::error::Error>> {
    if account.version != ACCOUNT_CONFIG_VERSION
        || account.owner_user_id <= 0
        || account.api_base_url.trim().is_empty()
        || account.realtime_url.trim().is_empty()
        || (!account.host_installation_id.is_empty()
            && !is_safe_identifier(&account.host_installation_id))
        || account.host_label.len() > 80
        || account.host_label.chars().any(char::is_control)
        || !is_safe_identifier(&account.service_label)
        || !account.service_binary.is_absolute()
        || account.provider_path.trim().is_empty()
        || account.providers.is_empty()
        || !matches!(secrets.version, 1 | ACCOUNT_SECRETS_VERSION)
        || secrets.owner_user_id != account.owner_user_id
        || secrets.control_token.trim().is_empty()
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge account config or credentials are incomplete or mismatched",
        )
        .into());
    }
    owner_credential(secrets)?;
    let mut retired_labels = HashSet::new();
    if account.superseded_service_labels.iter().any(|label| {
        !is_safe_identifier(label)
            || label == &account.service_label
            || !retired_labels.insert(label.as_str())
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge config contains invalid or duplicate superseded service labels",
        )
        .into());
    }
    let mut operator_ids = HashSet::new();
    if account
        .operator_user_ids
        .iter()
        .any(|user_id| *user_id <= 0 || !operator_ids.insert(*user_id))
        || (!account.operator_user_ids.is_empty() && !operator_ids.contains(&account.owner_user_id))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge operator allowlist is invalid or does not contain the owner",
        )
        .into());
    }
    let mut installation_ids = HashSet::new();
    let mut provider_ids = HashSet::new();
    let mut bot_user_ids = HashSet::new();
    let mut state_dirs = HashSet::new();
    for provider in &account.providers {
        if !is_safe_identifier(&provider.installation_id)
            || !is_safe_identifier(&provider.provider_id)
            || provider.bot_user_id <= 0
            || provider.bot_username.trim().is_empty()
            || provider.dm_chat_id.is_none_or(|id| id <= 0)
            || !provider.workspace.is_absolute()
            || !provider.executable.is_absolute()
            || provider.provider_runtime.as_ref().is_some_and(|runtime| {
                !runtime.is_absolute() || has_unsafe_path_components(runtime)
            })
            || !provider.state_dir.is_absolute()
            || has_unsafe_path_components(&provider.state_dir)
            || !installation_ids.insert(provider.installation_id.as_str())
            || !provider_ids.insert(provider.provider_id.as_str())
            || !bot_user_ids.insert(provider.bot_user_id)
            || !state_dirs.insert(provider.state_dir.as_path())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bridge provider installations contain incomplete or duplicate identities",
            )
            .into());
        }
    }
    let mut credential_ids = HashSet::new();
    let mut credential_bot_ids = HashSet::new();
    for credentials in &secrets.providers {
        if credentials.installation_id.trim().is_empty()
            || credentials.bot_user_id <= 0
            || credentials.bot_token.trim().is_empty()
            || !credential_ids.insert(credentials.installation_id.as_str())
            || !credential_bot_ids.insert(credentials.bot_user_id)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bridge provider credentials contain incomplete or duplicate identities",
            )
            .into());
        }
        let provider = account
            .providers
            .iter()
            .find(|provider| provider.installation_id == credentials.installation_id)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "bridge credentials reference an unknown provider installation",
                )
            })?;
        if provider.bot_user_id != credentials.bot_user_id {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "bridge credentials do not match the provider bot identity",
            )
            .into());
        }
    }
    if credential_ids != installation_ids {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "bridge provider config and credential namespaces do not match",
        )
        .into());
    }
    Ok(())
}

pub(super) fn owner_credential(
    secrets: &AccountBridgeSecrets,
) -> Result<AuthCredential, Box<dyn std::error::Error>> {
    let credential = match secrets.version {
        1 | ACCOUNT_SECRETS_VERSION
            if secrets.owner_auth.is_none() && !secrets.owner_token.trim().is_empty() =>
        {
            AuthCredential::AccessToken {
                token: AuthToken::try_new(&secrets.owner_token)?,
            }
        }
        ACCOUNT_SECRETS_VERSION
            if secrets.owner_token.trim().is_empty() && secrets.owner_auth.is_some() =>
        {
            secrets.owner_auth.clone().expect("checked owner auth")
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bridge owner credentials must select exactly one supported authority",
            )
            .into());
        }
    };
    if let AuthCredential::InlineProtocolV3 {
        permanent,
        temporary,
        public_keys,
    } = &credential
        && (permanent.temporary || !temporary.temporary || public_keys.is_empty())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bridge V3 owner credentials require permanent and temporary keys plus a pinned key ring",
        )
        .into());
    }
    Ok(credential)
}

pub(super) fn clear_bridge_owner_authority(
    paths: &BridgePaths,
    expected: &AuthCredential,
) -> Result<bool, Box<dyn std::error::Error>> {
    let _account_mutation_lock = acquire_account_mutation_lock(paths)?;
    let mut secrets: AccountBridgeSecrets = read_required_json(&paths.secrets)?;
    if owner_credential(&secrets).ok().as_ref() != Some(expected) {
        return Ok(false);
    }
    secrets.owner_auth = None;
    secrets.owner_token.clear();
    write_private_json(&paths.secrets, &secrets)?;
    Ok(true)
}

pub(super) fn is_safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 200
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

pub(super) fn has_unsafe_path_components(path: &Path) -> bool {
    path.components()
        .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
}

pub(super) fn primary_installation(
    account: &AccountBridgeConfig,
) -> Result<&ProviderInstallationConfig, Box<dyn std::error::Error>> {
    account.providers.first().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "no coding-agent provider is configured in this Inline account bridge",
        )
        .into()
    })
}

pub(super) fn provider_credentials<'a>(
    secrets: &'a AccountBridgeSecrets,
    installation: &ProviderInstallationConfig,
) -> Result<&'a ProviderCredentials, Box<dyn std::error::Error>> {
    secrets
        .providers
        .iter()
        .find(|credentials| credentials.installation_id == installation.installation_id)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "provider credentials are missing",
            )
            .into()
        })
}

pub(super) fn replace_provider(
    account: &mut AccountBridgeConfig,
    replacement: ProviderInstallationConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let provider = account
        .providers
        .iter_mut()
        .find(|provider| provider.installation_id == replacement.installation_id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "provider installation vanished"))?;
    *provider = replacement;
    Ok(())
}

pub(super) fn upsert_provider_identity(
    account: &mut AccountBridgeConfig,
    secrets: &mut AccountBridgeSecrets,
    installation: ProviderInstallationConfig,
    credentials: ProviderCredentials,
) -> Result<(), Box<dyn std::error::Error>> {
    if installation.installation_id != credentials.installation_id
        || installation.bot_user_id != credentials.bot_user_id
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "provider config and credentials identify different installations",
        )
        .into());
    }
    if let Some(existing) = account
        .providers
        .iter_mut()
        .find(|provider| provider.installation_id == installation.installation_id)
    {
        *existing = installation;
    } else {
        account.providers.push(installation);
    }
    if let Some(existing) = secrets
        .providers
        .iter_mut()
        .find(|secret| secret.installation_id == credentials.installation_id)
    {
        *existing = credentials;
    } else {
        secrets.providers.push(credentials);
    }
    Ok(())
}

pub(super) fn adopt_service_identity(
    account: &mut AccountBridgeConfig,
    desired_label: String,
    service_binary: PathBuf,
) {
    if account.service_label != desired_label
        && !account.service_label.trim().is_empty()
        && !account
            .superseded_service_labels
            .contains(&account.service_label)
    {
        account
            .superseded_service_labels
            .push(account.service_label.clone());
    }
    account.service_label = desired_label;
    account.service_binary = service_binary;
}

pub(super) fn print_status(
    result: &service::BridgeStatus,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    if json {
        output::print_json(result, json_format)?;
    } else if result.installed {
        println!("Bridge: {}", result.status);
        if let Some(name) = &result.display_name {
            println!("Bot: {name}");
        }
        if let Some(workspace) = &result.workspace {
            println!("Workspace: {}", workspace_label(Path::new(workspace)));
        }
        if let Some(detail) = &result.detail
            && !detail.is_empty()
        {
            println!("Detail: {detail}");
        }
    } else {
        println!("Bridge: not installed");
        println!("Run `inline setup codex` to get started. OpenCode and Claude are experimental.");
    }
    Ok(())
}
