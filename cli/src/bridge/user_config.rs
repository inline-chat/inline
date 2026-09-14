//! User-editable bridge policy stored in `~/.inline/config.toml`.

use std::collections::{BTreeMap, BTreeSet};

use super::*;

const AGENT_BRIDGE_CONFIG_VERSION: u32 = 1;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
struct InlineUserConfig {
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        alias = "agentBridge"
    )]
    agent_bridge: Option<AgentBridgeUserConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent_setup: Option<AgentSetupUserConfig>,
    #[serde(flatten)]
    other: BTreeMap<String, toml::Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
struct AgentSetupUserConfig {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    installations: Vec<AgentSetupInstallation>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub(crate) struct AgentSetupInstallation {
    pub(crate) target: String,
    pub(crate) instance: String,
    pub(crate) bot_user_id: i64,
    pub(crate) bot_username: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
struct AgentBridgeUserConfig {
    #[serde(default, rename = "version", skip_serializing)]
    legacy_version: Option<u32>,
    #[serde(default)]
    allowed_user_ids: Vec<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reply_threads: Option<ReplyThreadMode>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    providers: BTreeMap<String, ProviderPolicyConfig>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
struct ProviderPolicyConfig {
    #[serde(default)]
    allowed_user_ids: Vec<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reply_threads: Option<ReplyThreadMode>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyInlineUserConfig {
    #[serde(default)]
    agent_bridge: Option<LegacyAgentBridgeUserConfig>,
    #[serde(flatten)]
    other: BTreeMap<String, toml::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyAgentBridgeUserConfig {
    #[serde(default = "agent_bridge_config_version")]
    version: u32,
    #[serde(default)]
    users: BTreeMap<String, LegacyUserBridgePolicyConfig>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyUserBridgePolicyConfig {
    #[serde(default)]
    defaults: LegacyBridgePolicyConfig,
    #[serde(default)]
    providers: BTreeMap<String, LegacyProviderPolicyConfig>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyBridgePolicyConfig {
    #[serde(default)]
    operators: LegacyOperatorAllowlistConfig,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyProviderPolicyConfig {
    #[serde(default)]
    operators: Option<LegacyOperatorAllowlistConfig>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacyOperatorAllowlistConfig {
    #[serde(default)]
    allowed_user_ids: Vec<i64>,
}

impl LegacyInlineUserConfig {
    fn into_current(mut self, owner_user_id: i64) -> InlineUserConfig {
        let agent_bridge = self.agent_bridge.take().and_then(|mut agent_bridge| {
            agent_bridge
                .users
                .remove(&owner_user_id.to_string())
                .map(|user| {
                    let providers = user
                        .providers
                        .into_iter()
                        .filter_map(|(provider_id, provider)| {
                            provider.operators.map(|operators| {
                                (
                                    provider_id,
                                    ProviderPolicyConfig {
                                        allowed_user_ids: operators.allowed_user_ids,
                                        reply_threads: None,
                                    },
                                )
                            })
                        })
                        .collect();
                    AgentBridgeUserConfig {
                        legacy_version: Some(agent_bridge.version),
                        allowed_user_ids: user.defaults.operators.allowed_user_ids,
                        reply_threads: None,
                        providers,
                    }
                })
        });
        InlineUserConfig {
            agent_bridge,
            agent_setup: None,
            other: self.other,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperatorMutation {
    Add,
    Remove,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReplyThreadDefaultSource {
    Provider,
    Global,
    BuiltIn,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ReplyThreadDefault {
    pub mode: ReplyThreadMode,
    pub source: ReplyThreadDefaultSource,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OperatorPolicyOutput {
    config_path: String,
    scope: String,
    provider: Option<String>,
    source: String,
    owner_user_id: i64,
    allowed_user_ids: Vec<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    changed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    service_restarted: Option<bool>,
}

fn agent_bridge_config_version() -> u32 {
    AGENT_BRIDGE_CONFIG_VERSION
}

pub(super) fn inline_user_config_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let home = env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not configured"))?;
    Ok(PathBuf::from(home).join(".inline").join("config.toml"))
}

fn load_user_config(path: &Path) -> Result<Option<InlineUserConfig>, Box<dyn std::error::Error>> {
    let config = match fs::read_to_string(path) {
        Ok(contents) => Some(toml::from_str::<InlineUserConfig>(&contents)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    if let Some(config) = config.as_ref()
        && let Some(agent_bridge) = config.agent_bridge.as_ref()
    {
        validate_agent_bridge_config(agent_bridge)?;
    }
    if let Some(config) = config.as_ref()
        && let Some(agent_setup) = config.agent_setup.as_ref()
    {
        validate_agent_setup_config(agent_setup)?;
    }
    Ok(config)
}

fn legacy_user_config_path(path: &Path) -> PathBuf {
    path.with_extension("json")
}

fn load_legacy_user_config(
    path: &Path,
    owner_user_id: i64,
) -> Result<Option<InlineUserConfig>, Box<dyn std::error::Error>> {
    let legacy = read_optional_json::<LegacyInlineUserConfig>(path)?;
    if let Some(agent_bridge) = legacy
        .as_ref()
        .and_then(|config| config.agent_bridge.as_ref())
        && agent_bridge.version != AGENT_BRIDGE_CONFIG_VERSION
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "agent bridge config version {} is not supported (expected {})",
                agent_bridge.version, AGENT_BRIDGE_CONFIG_VERSION
            ),
        )
        .into());
    }
    let config = legacy.map(|config| config.into_current(owner_user_id));
    if let Some(config) = config.as_ref()
        && let Some(agent_bridge) = config.agent_bridge.as_ref()
    {
        validate_agent_bridge_config(agent_bridge)?;
    }
    Ok(config)
}

fn load_user_config_for_write(
    path: &Path,
    owner_user_id: i64,
) -> Result<Option<InlineUserConfig>, Box<dyn std::error::Error>> {
    if let Some(config) = load_user_config(path)? {
        return Ok(Some(config));
    }
    load_legacy_user_config(&legacy_user_config_path(path), owner_user_id)
}

fn write_private_toml<T: Serialize>(
    path: &Path,
    value: &T,
) -> Result<(), Box<dyn std::error::Error>> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "Inline config has no parent")
    })?;
    ensure_private_dir(parent)?;
    let temporary = path.with_extension("toml.tmp");
    let mut contents = toml::to_string_pretty(value)?;
    if !contents.ends_with('\n') {
        contents.push('\n');
    }
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
    set_file_mode(&temporary, 0o600)?;
    fs::rename(&temporary, path)?;
    set_file_mode(path, 0o600)?;
    Ok(())
}

fn acquire_user_config_lock(path: &Path) -> io::Result<fs::File> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "Inline config path has no parent",
        )
    })?;
    ensure_private_dir(parent)?;
    let lock_path = parent.join("config.lock");
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(&lock_path)?;
    set_file_mode(&lock_path, 0o600)?;
    file.lock().map_err(|error| {
        io::Error::other(format!("could not lock the Inline user config: {error}"))
    })?;
    Ok(file)
}

fn validate_agent_bridge_config(
    config: &AgentBridgeUserConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(version) = config.legacy_version
        && version != AGENT_BRIDGE_CONFIG_VERSION
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "agent bridge config version {} is not supported (expected {})",
                version, AGENT_BRIDGE_CONFIG_VERSION
            ),
        )
        .into());
    }
    validate_allowlist(&config.allowed_user_ids)?;
    for (provider_id, provider) in &config.providers {
        if !is_safe_identifier(provider_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("agent bridge config contains an invalid provider ID: {provider_id}"),
            )
            .into());
        }
        validate_allowlist(&provider.allowed_user_ids)?;
    }
    Ok(())
}

fn validate_allowlist(user_ids: &[i64]) -> Result<(), Box<dyn std::error::Error>> {
    let mut unique = BTreeSet::new();
    if user_ids
        .iter()
        .any(|user_id| *user_id <= 0 || !unique.insert(*user_id))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "agent bridge operator allowlists require unique positive user IDs",
        )
        .into());
    }
    Ok(())
}

fn validate_agent_setup_config(
    config: &AgentSetupUserConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut keys = BTreeSet::new();
    for installation in &config.installations {
        let valid_target = matches!(installation.target.as_str(), "openclaw" | "hermes");
        let valid_instance = installation.instance == "default"
            || installation
                .instance
                .strip_prefix("profile:")
                .is_some_and(is_safe_agent_profile);
        let valid_username = !installation.bot_username.is_empty()
            && installation.bot_username.len() <= 256
            && installation.bot_username.ends_with("bot")
            && installation
                .bot_username
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_');
        if !valid_target
            || !valid_instance
            || installation.bot_user_id <= 0
            || !valid_username
            || !keys.insert((&installation.target, &installation.instance))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "agent_setup contains an invalid or duplicate installation",
            )
            .into());
        }
    }
    Ok(())
}

fn is_safe_agent_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        && profile
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

pub(crate) fn agent_setup_installation(
    target: &str,
    instance: &str,
) -> Result<Option<AgentSetupInstallation>, Box<dyn std::error::Error>> {
    let path = inline_user_config_path()?;
    let config = load_user_config(&path)?;
    Ok(config
        .and_then(|config| config.agent_setup)
        .and_then(|config| {
            config.installations.into_iter().find(|installation| {
                installation.target == target && installation.instance == instance
            })
        }))
}

pub(crate) fn upsert_agent_setup_installation(
    owner_user_id: i64,
    installation: AgentSetupInstallation,
) -> Result<(), Box<dyn std::error::Error>> {
    let path = inline_user_config_path()?;
    let config_lock = acquire_user_config_lock(&path)?;
    let mut config = load_user_config_for_write(&path, owner_user_id)?.unwrap_or_default();
    let agent_setup = config.agent_setup.get_or_insert_with(Default::default);
    if let Some(existing) = agent_setup.installations.iter_mut().find(|existing| {
        existing.target == installation.target && existing.instance == installation.instance
    }) {
        *existing = installation;
    } else {
        agent_setup.installations.push(installation);
    }
    agent_setup.installations.sort_by(|left, right| {
        (&left.target, &left.instance).cmp(&(&right.target, &right.instance))
    });
    validate_agent_setup_config(agent_setup)?;
    write_private_toml(&path, &config)?;
    drop(config_lock);
    Ok(())
}

pub(crate) fn set_provider_operator_ids(
    account: &AccountBridgeConfig,
    provider_id: &str,
    allowed_user_ids: &[i64],
) -> Result<(), Box<dyn std::error::Error>> {
    configured_provider(account, provider_id)?;
    let mut allowed_user_ids = allowed_user_ids
        .iter()
        .copied()
        .filter(|user_id| *user_id != account.owner_user_id)
        .collect::<Vec<_>>();
    allowed_user_ids.sort_unstable();
    allowed_user_ids.dedup();
    validate_allowlist(&allowed_user_ids)?;

    let path = inline_user_config_path()?;
    let config_lock = acquire_user_config_lock(&path)?;
    let mut config = load_user_config_for_write(&path, account.owner_user_id)?.unwrap_or_default();
    let agent_bridge = config
        .agent_bridge
        .get_or_insert_with(|| initial_agent_bridge_config(account));
    let reply_threads = agent_bridge.reply_threads;
    let provider = agent_bridge
        .providers
        .entry(provider_id.to_string())
        .or_insert_with(|| ProviderPolicyConfig {
            allowed_user_ids: Vec::new(),
            reply_threads,
        });
    provider.allowed_user_ids = allowed_user_ids;
    validate_agent_bridge_config(agent_bridge)?;
    write_private_toml(&path, &config)?;
    drop(config_lock);
    Ok(())
}

fn configured_provider<'a>(
    account: &'a AccountBridgeConfig,
    provider_id: &str,
) -> Result<&'a ProviderInstallationConfig, Box<dyn std::error::Error>> {
    account
        .providers
        .iter()
        .find(|provider| provider.provider_id == provider_id)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("{provider_id} is not configured for this bridge"),
            )
            .into()
        })
}

fn effective_operator_ids<'a>(
    account: &'a AccountBridgeConfig,
    provider_id: &str,
    config: Option<&'a InlineUserConfig>,
) -> (&'a [i64], &'static str) {
    let Some(agent_bridge) = config.and_then(|config| config.agent_bridge.as_ref()) else {
        return (&account.operator_user_ids, "legacy_manifest");
    };
    if let Some(provider) = agent_bridge.providers.get(provider_id) {
        (&provider.allowed_user_ids, "provider_override")
    } else {
        (&agent_bridge.allowed_user_ids, "global_default")
    }
}

fn initial_agent_bridge_config(account: &AccountBridgeConfig) -> AgentBridgeUserConfig {
    let legacy_allowed = account
        .operator_user_ids
        .iter()
        .copied()
        .filter(|candidate| *candidate != account.owner_user_id)
        .collect();
    AgentBridgeUserConfig {
        legacy_version: None,
        allowed_user_ids: legacy_allowed,
        reply_threads: None,
        providers: BTreeMap::new(),
    }
}

pub(super) fn ensure_operator_user_config(
    account: &AccountBridgeConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let path = inline_user_config_path()?;
    ensure_operator_user_config_at(&path, account)
}

fn ensure_operator_user_config_at(
    path: &Path,
    account: &AccountBridgeConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let config_lock = acquire_user_config_lock(path)?;
    let mut user_config =
        load_user_config_for_write(path, account.owner_user_id)?.unwrap_or_default();
    let agent_bridge = user_config
        .agent_bridge
        .get_or_insert_with(|| initial_agent_bridge_config(account));
    validate_agent_bridge_config(agent_bridge)?;
    write_private_toml(path, &user_config)?;
    drop(config_lock);
    Ok(())
}

pub(super) fn operator_policy_for_provider(
    account: &AccountBridgeConfig,
    provider_id: &str,
) -> Result<OperatorPolicy, Box<dyn std::error::Error>> {
    configured_provider(account, provider_id)?;
    let path = inline_user_config_path()?;
    let config = load_user_config(&path)?;
    let (allowed_user_ids, _) = effective_operator_ids(account, provider_id, config.as_ref());
    Ok(OperatorPolicy::from_allowed(
        account.owner_user_id,
        allowed_user_ids.iter().copied(),
    )?)
}

fn effective_reply_thread_default(
    provider_id: &str,
    config: Option<&InlineUserConfig>,
) -> ReplyThreadDefault {
    let Some(agent_bridge) = config.and_then(|config| config.agent_bridge.as_ref()) else {
        return ReplyThreadDefault {
            mode: ReplyThreadMode::Auto,
            source: ReplyThreadDefaultSource::BuiltIn,
        };
    };
    if let Some(mode) = agent_bridge
        .providers
        .get(provider_id)
        .and_then(|provider| provider.reply_threads)
    {
        ReplyThreadDefault {
            mode,
            source: ReplyThreadDefaultSource::Provider,
        }
    } else if let Some(mode) = agent_bridge.reply_threads {
        ReplyThreadDefault {
            mode,
            source: ReplyThreadDefaultSource::Global,
        }
    } else {
        ReplyThreadDefault {
            mode: ReplyThreadMode::Auto,
            source: ReplyThreadDefaultSource::BuiltIn,
        }
    }
}

pub(super) fn reply_thread_default_for_provider(
    account: &AccountBridgeConfig,
    provider_id: &str,
) -> Result<ReplyThreadDefault, Box<dyn std::error::Error>> {
    configured_provider(account, provider_id)?;
    let path = inline_user_config_path()?;
    let config = load_user_config(&path)?;
    Ok(effective_reply_thread_default(provider_id, config.as_ref()))
}

pub(super) fn add_operator_for_provider(
    owner_user_id: i64,
    provider_id: &str,
    user_id: i64,
) -> Result<OperatorPolicy, Box<dyn std::error::Error>> {
    if owner_user_id <= 0 || user_id <= 0 || !is_safe_identifier(provider_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "operator policy requires positive user IDs and a valid provider ID",
        )
        .into());
    }
    let path = inline_user_config_path()?;
    let config_lock = acquire_user_config_lock(&path)?;
    let mut user_config = load_user_config_for_write(&path, owner_user_id)?.unwrap_or_default();
    let agent_bridge = user_config
        .agent_bridge
        .get_or_insert_with(AgentBridgeUserConfig::default);
    let global_allowed_user_ids = agent_bridge.allowed_user_ids.clone();
    let allowed_user_ids = &mut agent_bridge
        .providers
        .entry(provider_id.to_string())
        .or_insert_with(|| ProviderPolicyConfig {
            allowed_user_ids: global_allowed_user_ids,
            reply_threads: None,
        })
        .allowed_user_ids;
    if user_id != owner_user_id && !allowed_user_ids.contains(&user_id) {
        allowed_user_ids.push(user_id);
    }
    allowed_user_ids.sort_unstable();
    allowed_user_ids.dedup();
    let updated_allowed_user_ids = allowed_user_ids.clone();
    validate_agent_bridge_config(agent_bridge)?;
    write_private_toml(&path, &user_config)?;
    drop(config_lock);
    Ok(OperatorPolicy::from_allowed(
        owner_user_id,
        updated_allowed_user_ids,
    )?)
}

pub fn operators_list(
    config: &Config,
    provider_id: Option<&str>,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let loaded = load_installation(config)?;
    let path = inline_user_config_path()?;
    let user_config = load_user_config(&path)?;
    let selected = provider_id
        .map(|provider_id| configured_provider(&loaded.account, provider_id))
        .transpose()?;
    let effective_provider_id = selected
        .map(|provider| provider.provider_id.as_str())
        .or_else(|| {
            loaded
                .account
                .providers
                .first()
                .map(|provider| provider.provider_id.as_str())
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no providers are configured"))?;
    let (allowed, source) = if provider_id.is_some() {
        effective_operator_ids(&loaded.account, effective_provider_id, user_config.as_ref())
    } else if let Some(agent_bridge) = user_config
        .as_ref()
        .and_then(|config| config.agent_bridge.as_ref())
    {
        (agent_bridge.allowed_user_ids.as_slice(), "global_default")
    } else {
        (
            loaded.account.operator_user_ids.as_slice(),
            "legacy_manifest",
        )
    };
    let output = operator_output(
        &path,
        &loaded.account,
        provider_id,
        source,
        allowed,
        None,
        None,
    );
    print_operator_output(&output, json, json_format)
}

pub async fn operators_mutate(
    config: &Config,
    provider_id: Option<&str>,
    user_id: i64,
    mutation: OperatorMutation,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    if user_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "operator user ID must be positive",
        )
        .into());
    }
    let loaded = load_installation(config)?;
    if mutation == OperatorMutation::Remove && user_id == loaded.account.owner_user_id {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "the bridge owner cannot be removed from the operator allowlist",
        )
        .into());
    }
    if let Some(provider_id) = provider_id {
        configured_provider(&loaded.account, provider_id)?;
    }

    let path = inline_user_config_path()?;
    let config_lock = acquire_user_config_lock(&path)?;
    let mut user_config =
        load_user_config_for_write(&path, loaded.account.owner_user_id)?.unwrap_or_default();
    user_config
        .agent_bridge
        .get_or_insert_with(|| initial_agent_bridge_config(&loaded.account));
    let agent_bridge = user_config
        .agent_bridge
        .as_mut()
        .expect("agent bridge config initialized");
    let global_allowed_user_ids = agent_bridge.allowed_user_ids.clone();
    let allowed_user_ids = match provider_id {
        Some(provider_id) => {
            &mut agent_bridge
                .providers
                .entry(provider_id.to_string())
                .or_insert_with(|| ProviderPolicyConfig {
                    allowed_user_ids: global_allowed_user_ids,
                    reply_threads: None,
                })
                .allowed_user_ids
        }
        None => &mut agent_bridge.allowed_user_ids,
    };
    let changed = match mutation {
        OperatorMutation::Add if user_id == loaded.account.owner_user_id => false,
        OperatorMutation::Add => {
            if allowed_user_ids.contains(&user_id) {
                false
            } else {
                allowed_user_ids.push(user_id);
                true
            }
        }
        OperatorMutation::Remove => {
            let previous_len = allowed_user_ids.len();
            allowed_user_ids.retain(|candidate| *candidate != user_id);
            allowed_user_ids.len() != previous_len
        }
    };
    allowed_user_ids.sort_unstable();
    allowed_user_ids.dedup();
    let updated_allowed_user_ids = allowed_user_ids.clone();
    validate_agent_bridge_config(agent_bridge)?;
    write_private_toml(&path, &user_config)?;
    drop(config_lock);

    service::restart_service(&loaded.paths, &loaded.account, &loaded.secrets).await?;
    let output = operator_output(
        &path,
        &loaded.account,
        provider_id,
        if provider_id.is_some() {
            "provider_override"
        } else {
            "global_default"
        },
        &updated_allowed_user_ids,
        Some(changed),
        Some(true),
    );
    print_operator_output(&output, json, json_format)
}

#[allow(clippy::too_many_arguments)]
fn operator_output(
    path: &Path,
    account: &AccountBridgeConfig,
    provider_id: Option<&str>,
    source: &str,
    allowed_user_ids: &[i64],
    changed: Option<bool>,
    service_restarted: Option<bool>,
) -> OperatorPolicyOutput {
    let mut allowed_user_ids = allowed_user_ids.to_vec();
    allowed_user_ids.push(account.owner_user_id);
    allowed_user_ids.sort_unstable();
    allowed_user_ids.dedup();
    OperatorPolicyOutput {
        config_path: path.display().to_string(),
        scope: provider_id
            .map_or("all_providers", |_| "provider")
            .to_string(),
        provider: provider_id.map(str::to_string),
        source: source.to_string(),
        owner_user_id: account.owner_user_id,
        allowed_user_ids,
        changed,
        service_restarted,
    }
}

fn print_operator_output(
    output: &OperatorPolicyOutput,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    if json {
        output::print_json(output, json_format)?;
    } else {
        println!("Operator scope: {}", output.scope);
        if let Some(provider) = output.provider.as_deref() {
            println!("Provider: {provider}");
        }
        println!(
            "Allowed user IDs: {}",
            output
                .allowed_user_ids
                .iter()
                .map(i64::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
        println!("Config: {}", output.config_path);
        if output.service_restarted == Some(true) {
            println!("Background bridge restarted with the updated policy.");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account() -> AccountBridgeConfig {
        let (account, _) = crate::bridge::tests::account_fixture();
        account
    }

    #[test]
    fn global_policy_applies_to_every_provider_and_provider_policy_replaces_it() {
        let mut account = account();
        let mut claude = account.providers[0].clone();
        claude.installation_id = "claude".to_string();
        claude.provider_id = "claude".to_string();
        claude.bot_user_id = 85;
        account.providers.push(claude);
        let config: InlineUserConfig = toml::from_str(
            r#"
                [agent_bridge]
                allowed_user_ids = [50]

                [agent_bridge.providers.claude]
                allowed_user_ids = [60]
            "#,
        )
        .expect("config");
        validate_agent_bridge_config(config.agent_bridge.as_ref().expect("bridge config"))
            .expect("valid config");

        let (codex, codex_source) = effective_operator_ids(&account, "codex", Some(&config));
        let (claude, claude_source) = effective_operator_ids(&account, "claude", Some(&config));
        assert_eq!(codex, [50]);
        assert_eq!(codex_source, "global_default");
        assert_eq!(claude, [60]);
        assert_eq!(claude_source, "provider_override");
    }

    #[test]
    fn reply_thread_defaults_resolve_provider_then_global_then_builtin() {
        let configured: InlineUserConfig = toml::from_str(
            r#"
                [agent_bridge]
                reply_threads = "on"

                [agent_bridge.providers.claude]
                reply_threads = "off"
            "#,
        )
        .expect("config");

        assert_eq!(
            effective_reply_thread_default("claude", Some(&configured)),
            ReplyThreadDefault {
                mode: ReplyThreadMode::Off,
                source: ReplyThreadDefaultSource::Provider,
            }
        );
        assert_eq!(
            effective_reply_thread_default("codex", Some(&configured)),
            ReplyThreadDefault {
                mode: ReplyThreadMode::On,
                source: ReplyThreadDefaultSource::Global,
            }
        );
        let built_in = effective_reply_thread_default("codex", None);
        assert_eq!(
            built_in,
            ReplyThreadDefault {
                mode: ReplyThreadMode::Auto,
                source: ReplyThreadDefaultSource::BuiltIn,
            }
        );
    }

    #[test]
    fn toml_schema_is_single_user_with_direct_provider_overrides() {
        let config = InlineUserConfig {
            agent_bridge: Some(AgentBridgeUserConfig {
                legacy_version: None,
                allowed_user_ids: vec![50],
                reply_threads: Some(ReplyThreadMode::Auto),
                providers: BTreeMap::from([(
                    "claude".to_string(),
                    ProviderPolicyConfig {
                        allowed_user_ids: vec![60],
                        reply_threads: Some(ReplyThreadMode::Off),
                    },
                )]),
            }),
            agent_setup: None,
            other: BTreeMap::new(),
        };

        let encoded = toml::to_string_pretty(&config).expect("serialize config");
        let document = encoded.parse::<toml::Value>().expect("parse config");
        let bridge = document
            .get("agent_bridge")
            .and_then(toml::Value::as_table)
            .expect("agent bridge table");
        assert_eq!(bridge["allowed_user_ids"].as_array().map(Vec::len), Some(1));
        assert!(!bridge.contains_key("version"));
        assert!(!bridge.contains_key("users"));
        assert_eq!(bridge["reply_threads"].as_str(), Some("auto"));
        let provider = bridge["providers"]["claude"]
            .as_table()
            .expect("provider table");
        assert_eq!(
            provider["allowed_user_ids"].as_array().map(Vec::len),
            Some(1)
        );
        assert!(!provider.contains_key("operators"));
        assert_eq!(provider["reply_threads"].as_str(), Some("off"));
    }

    #[test]
    fn policy_validation_rejects_duplicate_or_nonpositive_ids() {
        for allowed_user_ids in [vec![8, 8], vec![0], vec![-1]] {
            let config = AgentBridgeUserConfig {
                legacy_version: None,
                allowed_user_ids,
                reply_threads: None,
                providers: BTreeMap::new(),
            };
            assert!(validate_agent_bridge_config(&config).is_err());
        }

        let config = AgentBridgeUserConfig {
            legacy_version: None,
            allowed_user_ids: Vec::new(),
            reply_threads: None,
            providers: BTreeMap::from([(
                "unsafe provider".to_string(),
                ProviderPolicyConfig::default(),
            )]),
        };
        assert!(validate_agent_bridge_config(&config).is_err());
    }

    #[test]
    fn setup_creates_a_user_default_without_losing_other_config() {
        let directory = tempfile::tempdir().expect("config directory");
        let path = directory.path().join("config.toml");
        let seed: InlineUserConfig =
            toml::from_str("[unrelatedSetting]\npreserve = true\n").expect("seed config");
        write_private_toml(&path, &seed).expect("write seed config");

        let account = account();
        ensure_operator_user_config_at(&path, &account).expect("ensure bridge config");
        let encoded = fs::read_to_string(&path).expect("read config");
        assert!(!encoded.contains("version"));
        assert!(!encoded.contains("providers"));
        let config = load_user_config(&path)
            .expect("load config")
            .expect("config exists");
        assert_eq!(
            config.other["unrelatedSetting"]["preserve"].as_bool(),
            Some(true)
        );
        let agent_bridge = config.agent_bridge.expect("agent bridge config");
        assert!(agent_bridge.allowed_user_ids.is_empty());
    }

    #[test]
    fn agent_setup_is_sparse_and_preserves_unrelated_top_level_config() {
        let config: InlineUserConfig = toml::from_str(
            r#"
                theme = "system"

                [notifications]
                sound = false

                [[agent_setup.installations]]
                target = "openclaw"
                instance = "default"
                bot_user_id = 42
                bot_username = "inline_openclaw_42_37a8ee_bot"
            "#,
        )
        .expect("parse sparse setup config");
        validate_agent_setup_config(config.agent_setup.as_ref().expect("agent setup"))
            .expect("validate setup config");

        let encoded = toml::to_string_pretty(&config).expect("serialize config");
        let decoded: InlineUserConfig = toml::from_str(&encoded).expect("reparse config");
        assert_eq!(decoded.other["theme"].as_str(), Some("system"));
        assert_eq!(
            decoded.other["notifications"]["sound"].as_bool(),
            Some(false)
        );
        let installations = decoded.agent_setup.expect("agent setup").installations;
        assert_eq!(installations.len(), 1);
        assert_eq!(installations[0].bot_user_id, 42);
        assert!(!encoded.contains("token"));
        assert!(!encoded.contains("version"));
    }

    #[test]
    fn agent_setup_rejects_unknown_fields_and_duplicate_installations() {
        assert!(
            toml::from_str::<InlineUserConfig>(
                r#"
                    [[agent_setup.installations]]
                    target = "hermes"
                    instance = "default"
                    bot_user_id = 42
                    bot_username = "inline_hermes_42_37a8ee_bot"
                    credential = "must-not-be-accepted"
                "#,
            )
            .is_err()
        );

        let duplicated = AgentSetupUserConfig {
            installations: vec![
                AgentSetupInstallation {
                    target: "hermes".to_string(),
                    instance: "default".to_string(),
                    bot_user_id: 42,
                    bot_username: "inline_hermes_42_37a8ee_bot".to_string(),
                },
                AgentSetupInstallation {
                    target: "hermes".to_string(),
                    instance: "default".to_string(),
                    bot_user_id: 43,
                    bot_username: "inline_hermes_43_37a8ee_bot".to_string(),
                },
            ],
        };
        assert!(validate_agent_setup_config(&duplicated).is_err());
    }

    #[test]
    fn setup_migrates_legacy_json_to_toml_without_deleting_it() {
        let directory = tempfile::tempdir().expect("config directory");
        let path = directory.path().join("config.toml");
        let legacy_path = legacy_user_config_path(&path);
        write_private_json(
            &legacy_path,
            &serde_json::json!({
                "unrelatedSetting": { "preserve": true },
                "agentBridge": {
                    "version": 1,
                    "users": {
                        "42": {
                            "defaults": { "operators": { "allowedUserIds": [50] } },
                            "providers": {
                                "claude": {
                                    "operators": { "allowedUserIds": [60] }
                                }
                            }
                        },
                        "99": {
                            "defaults": { "operators": { "allowedUserIds": [70] } }
                        }
                    }
                }
            }),
        )
        .expect("seed legacy config");

        let account = account();
        ensure_operator_user_config_at(&path, &account).expect("migrate bridge config");

        assert!(legacy_path.is_file(), "migration must retain legacy JSON");
        let config = load_user_config(&path)
            .expect("load TOML config")
            .expect("TOML config exists");
        assert_eq!(
            config.other["unrelatedSetting"]["preserve"].as_bool(),
            Some(true)
        );
        let agent_bridge = config.agent_bridge.expect("agent bridge config");
        assert_eq!(agent_bridge.allowed_user_ids, [50]);
        assert_eq!(agent_bridge.providers["claude"].allowed_user_ids, [60]);

        write_private_json(
            &legacy_path,
            &serde_json::json!({
                "agentBridge": {
                    "version": 1,
                    "users": {
                        "42": {
                            "defaults": { "operators": { "allowedUserIds": [70] } }
                        }
                    }
                }
            }),
        )
        .expect("change retained legacy backup");
        ensure_operator_user_config_at(&path, &account).expect("re-ensure TOML config");
        let config = load_user_config(&path)
            .expect("reload TOML config")
            .expect("TOML config exists");
        assert_eq!(
            config
                .agent_bridge
                .expect("agent bridge config")
                .allowed_user_ids,
            [50],
            "retained legacy JSON must not override TOML"
        );
    }
}
