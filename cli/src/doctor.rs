use serde::Serialize;
use std::env;

use crate::auth::AuthStore;
use crate::config::Config;
use crate::identity as client_info;
use crate::output;
use crate::state::LocalDb;
use crate::user_display_name;
use inline_protocol::proto;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DoctorOutput {
    system: DoctorSystem,
    client: DoctorClient,
    config: DoctorConfig,
    paths: DoctorPaths,
    auth: DoctorAuth,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorSystem {
    version: String,
    debug: bool,
    os: String,
    arch: String,
    executable: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorClient {
    client_type: String,
    client_version: String,
    user_agent: String,
    os_version: Option<String>,
    device_name: Option<String>,
    client_type_header: String,
    client_version_header: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorConfig {
    api_base_url: String,
    realtime_url: String,
    release_manifest_url: Option<String>,
    release_install_url: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorPaths {
    data_dir: String,
    data_dir_exists: bool,
    secrets_path: String,
    secrets_exists: bool,
    state_path: String,
    state_exists: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorAuth {
    token_present: bool,
    token_source: Option<String>,
    token_error: Option<String>,
    current_user: Option<proto::User>,
    state_error: Option<String>,
}

pub(crate) fn build_doctor_output(
    config: &Config,
    auth_store: &AuthStore,
    local_db: &LocalDb,
) -> DoctorOutput {
    let debug = cfg!(debug_assertions);
    let executable = env::current_exe()
        .ok()
        .map(|path| path.display().to_string());

    let env_token = env::var("INLINE_TOKEN")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let mut token_present = false;
    let mut token_source = None;
    let mut token_error = None;

    if env_token.is_some() {
        token_present = true;
        token_source = Some("INLINE_TOKEN".to_string());
    } else {
        match auth_store.load_token() {
            Ok(Some(_)) => {
                token_present = true;
                token_source = Some("secrets_file".to_string());
            }
            Ok(None) => {}
            Err(err) => {
                token_error = Some(err.to_string());
            }
        }
    }

    let (current_user, state_error) = match local_db.load() {
        Ok(state) => (state.current_user, None),
        Err(err) => (None, Some(err.to_string())),
    };

    DoctorOutput {
        system: DoctorSystem {
            version: env!("CARGO_PKG_VERSION").to_string(),
            debug,
            os: env::consts::OS.to_string(),
            arch: env::consts::ARCH.to_string(),
            executable,
        },
        client: build_doctor_client(),
        config: DoctorConfig {
            api_base_url: config.api_base_url.clone(),
            realtime_url: config.realtime_url.clone(),
            release_manifest_url: config.release_manifest_url.clone(),
            release_install_url: config.release_install_url.clone(),
        },
        paths: DoctorPaths {
            data_dir: config.data_dir.display().to_string(),
            data_dir_exists: config.data_dir.exists(),
            secrets_path: config.secrets_path.display().to_string(),
            secrets_exists: config.secrets_path.exists(),
            state_path: config.state_path.display().to_string(),
            state_exists: config.state_path.exists(),
        },
        auth: DoctorAuth {
            token_present,
            token_source,
            token_error,
            current_user,
            state_error,
        },
    }
}

pub(crate) fn print_doctor(output: &DoctorOutput) {
    print_section("System");
    println!("  version: {}", output.system.version);
    println!(
        "  debug build: {}",
        if output.system.debug { "yes" } else { "no" }
    );
    println!("  os: {}", output.system.os);
    println!("  arch: {}", output.system.arch);
    println!(
        "  executable: {}",
        output.system.executable.as_deref().unwrap_or("-")
    );

    print_section_after_break("Client");
    println!("  type: {}", output.client.client_type);
    println!("  version: {}", output.client.client_version);
    println!("  user agent: {}", output.client.user_agent);
    println!(
        "  os version: {}",
        output.client.os_version.as_deref().unwrap_or("-")
    );
    println!(
        "  device name: {}",
        output.client.device_name.as_deref().unwrap_or("-")
    );
    println!(
        "  metadata headers: {}, {}",
        output.client.client_type_header, output.client.client_version_header
    );

    print_section_after_break("Config");
    println!("  api base url: {}", output.config.api_base_url);
    println!("  realtime url: {}", output.config.realtime_url);
    println!(
        "  release manifest url: {}",
        output.config.release_manifest_url.as_deref().unwrap_or("-")
    );
    println!(
        "  release install url: {}",
        output.config.release_install_url.as_deref().unwrap_or("-")
    );

    print_section_after_break("Paths");
    println!(
        "  data dir: {} ({})",
        output.paths.data_dir,
        if output.paths.data_dir_exists {
            "exists"
        } else {
            "missing"
        }
    );
    println!(
        "  secrets file: {} ({})",
        output.paths.secrets_path,
        if output.paths.secrets_exists {
            "exists"
        } else {
            "missing"
        }
    );
    println!(
        "  state file: {} ({})",
        output.paths.state_path,
        if output.paths.state_exists {
            "exists"
        } else {
            "missing"
        }
    );

    print_section_after_break("Auth");
    if output.auth.token_present {
        if let Some(source) = &output.auth.token_source {
            println!("  token: present ({source})");
        } else {
            println!("  token: present");
        }
    } else {
        println!("  token: absent");
    }

    if let Some(user) = &output.auth.current_user {
        println!(
            "  current user: {} (id {})",
            user_display_name(user),
            user.id
        );
    } else {
        println!("  current user: -");
    }

    if let Some(error) = &output.auth.token_error {
        println!("  token error: {}", error);
    }
    if let Some(error) = &output.auth.state_error {
        println!("  state error: {}", error);
    }
}

fn print_section(title: &str) {
    println!("{}", output::style_heading(title));
}

fn print_section_after_break(title: &str) {
    println!();
    print_section(title);
}

fn build_doctor_client() -> DoctorClient {
    DoctorClient {
        client_type: client_info::client_type().to_string(),
        client_version: client_info::client_version().to_string(),
        user_agent: client_info::user_agent(),
        os_version: client_info::current_os_version(),
        device_name: client_info::device_name(),
        client_type_header: client_info::CLIENT_TYPE_HEADER.to_string(),
        client_version_header: client_info::CLIENT_VERSION_HEADER.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doctor_client_diagnostics_match_client_metadata() {
        let output = build_doctor_client();

        assert_eq!(output.client_type, client_info::client_type());
        assert_eq!(output.client_version, client_info::client_version());
        assert_eq!(output.user_agent, client_info::user_agent());
        assert_eq!(output.client_type_header, client_info::CLIENT_TYPE_HEADER);
        assert_eq!(
            output.client_version_header,
            client_info::CLIENT_VERSION_HEADER
        );
        assert!(
            output
                .device_name
                .as_deref()
                .map(|name| !name.is_empty())
                .unwrap_or(true)
        );
    }
}
