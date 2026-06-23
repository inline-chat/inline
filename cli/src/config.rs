use std::env;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Config {
    pub api_base_url: String,
    pub realtime_url: String,
    pub data_dir: PathBuf,
    pub secrets_path: PathBuf,
    pub state_path: PathBuf,
    pub release_manifest_url: Option<String>,
    pub release_install_url: Option<String>,
}

impl Config {
    pub fn load() -> Self {
        let debug = cfg!(debug_assertions);
        let api_base_url = env::var("INLINE_API_BASE_URL").unwrap_or_else(|_| {
            if debug {
                "http://localhost:8000/v1".to_string()
            } else {
                "https://api.inline.chat/v1".to_string()
            }
        });
        let api_base_url = api_base_url.trim_end_matches('/').to_string();

        let realtime_url = env::var("INLINE_REALTIME_URL").unwrap_or_else(|_| {
            if debug {
                "ws://localhost:8000/realtime".to_string()
            } else {
                "wss://api.inline.chat/realtime".to_string()
            }
        });
        let realtime_url = realtime_url.trim_end_matches('/').to_string();

        let data_dir = env::var("INLINE_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| default_data_dir(debug));
        let secrets_path = env::var("INLINE_SECRETS_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| data_dir.join("secrets.json"));
        let state_path = env::var("INLINE_STATE_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| data_dir.join("state.json"));

        let release_base_url = env::var("INLINE_RELEASE_BASE_URL")
            .ok()
            .or_else(|| if debug { None } else { Some(DEFAULT_RELEASE_BASE_URL.to_string()) })
            .map(|url| url.trim_end_matches('/').to_string());
        let release_manifest_url = env::var("INLINE_RELEASE_MANIFEST_URL")
            .ok()
            .or_else(|| release_base_url.as_ref().map(|base| format!("{base}/manifest.json")));
        let release_install_url = env::var("INLINE_RELEASE_INSTALL_URL")
            .ok()
            .or_else(|| release_base_url.as_ref().map(|base| format!("{base}/install.sh")));

        Self {
            api_base_url,
            realtime_url,
            data_dir,
            secrets_path,
            state_path,
            release_manifest_url,
            release_install_url,
        }
    }
}

const DEFAULT_RELEASE_BASE_URL: &str = "https://public-assets.inline.chat/cli";

fn default_data_dir(debug: bool) -> PathBuf {
    let base = env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    let dir_name = if debug { "inline-dev" } else { "inline" };
    base.join(".local").join("share").join(dir_name)
}
