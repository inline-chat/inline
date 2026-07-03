use dialoguer::{Input, Select};
use serde::Serialize;

use crate::api::{ApiClient, ApiError};
use crate::auth::AuthStore;
use crate::client_info::{self, AuthMetadata};
use crate::errors::CliError;
use crate::protocol::proto;
use crate::realtime::RealtimeClient;
use crate::state::LocalDb;
use crate::{AuthLoginArgs, fetch_me, is_interactive_terminal, user_display_name};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AuthLogoutOutput {
    pub(crate) saved_token_cleared: bool,
    pub(crate) effective_token_present: bool,
    pub(crate) effective_token_source: Option<String>,
    pub(crate) warning: Option<String>,
}

#[derive(Clone)]
pub(crate) enum Contact {
    Email(String),
    Phone(String),
}

pub(crate) async fn handle_login(
    args: AuthLoginArgs,
    api: &ApiClient,
    auth_store: &AuthStore,
    realtime_url: &str,
    local_db: &LocalDb,
    json: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut contact = contact_from_args(args)?;
    if json {
        return Err(CliError::interactive_required(
            "auth login does not support JSON/non-interactive verification yet",
            vec![
                "inline auth login".to_string(),
                "INLINE_TOKEN=... inline auth me --json".to_string(),
            ],
        )
        .into());
    }
    if !is_interactive_terminal() {
        let action = if contact.is_some() {
            "enter the login verification code"
        } else {
            "choose email/phone and enter the login verification code"
        };
        return Err(CliError::interactive_required(
            action,
            vec![
                "inline auth login --email you@example.com".to_string(),
                "INLINE_TOKEN=... inline auth me --json".to_string(),
            ],
        )
        .into());
    }

    let device_name = client_info::device_name();
    let device_id = auth_store.device_id()?;
    let auth_metadata = AuthMetadata::cli(&device_id, device_name.as_deref());

    loop {
        let current = match contact.take() {
            Some(value) => value,
            None => prompt_contact()?,
        };

        let email_challenge_token = match &current {
            Contact::Email(email) => {
                api.send_email_code(email, auth_metadata)
                    .await?
                    .challenge_token
            }
            Contact::Phone(phone) => {
                api.send_sms_code(phone, auth_metadata).await?;
                None
            }
        };

        loop {
            let code = prompt_code()?;
            let result = match &current {
                Contact::Email(email) => {
                    api.verify_email_code(
                        email,
                        &code,
                        email_challenge_token.as_deref(),
                        auth_metadata,
                    )
                    .await
                }
                Contact::Phone(phone) => api.verify_sms_code(phone, &code, auth_metadata).await,
            };

            match result {
                Ok(result) => {
                    auth_store.store_token(&result.token)?;
                    let mut realtime = RealtimeClient::connect(realtime_url, &result.token).await?;
                    match fetch_me(&mut realtime).await {
                        Ok(me) => {
                            local_db.set_current_user(me.clone())?;
                            let name = user_display_name(&me);
                            println!("Welcome, {}.", name);
                        }
                        Err(error) => {
                            eprintln!("Logged in, but failed to load profile: {error}");
                            println!("Logged in as user {}.", result.user_id);
                        }
                    }
                    return Ok(());
                }
                Err(error) => {
                    print_auth_error(&error);
                    let retry = Select::new()
                        .items(&["Try code again", "Edit email/phone"])
                        .default(0)
                        .interact()?;
                    if retry == 0 {
                        continue;
                    }
                    contact = None;
                    break;
                }
            }
        }
    }
}

fn prompt_code() -> Result<String, Box<dyn std::error::Error>> {
    if !is_interactive_terminal() {
        return Err(CliError::interactive_required(
            "enter the login verification code",
            vec!["inline auth login --email you@example.com".to_string()],
        )
        .into());
    }
    let code: String = Input::new().with_prompt("Code").interact_text()?;
    Ok(code.trim().to_string())
}

pub(crate) fn contact_from_args(
    args: AuthLoginArgs,
) -> Result<Option<Contact>, Box<dyn std::error::Error>> {
    if args.email.is_some() && args.phone.is_some() {
        return Err(CliError::invalid_args("Provide only one of --email or --phone").into());
    }

    if let Some(email) = args.email {
        return Ok(Some(Contact::Email(email.trim().to_string())));
    }

    if let Some(phone) = args.phone {
        return Ok(Some(Contact::Phone(phone.trim().to_string())));
    }

    Ok(None)
}

fn prompt_contact() -> Result<Contact, Box<dyn std::error::Error>> {
    if !is_interactive_terminal() {
        return Err(CliError::interactive_required(
            "choose email or phone for login",
            vec![
                "inline auth login --email you@example.com".to_string(),
                "inline auth login --phone +15551234567".to_string(),
            ],
        )
        .into());
    }
    let options = ["Email", "Phone"];
    let selection = Select::new().items(&options).default(0).interact()?;

    match selection {
        0 => {
            let email: String = Input::new().with_prompt("Email").interact_text()?;
            Ok(Contact::Email(email.trim().to_string()))
        }
        _ => {
            let phone: String = Input::new()
                .with_prompt("Phone (E.164 recommended)")
                .interact_text()?;
            Ok(Contact::Phone(phone.trim().to_string()))
        }
    }
}

pub(crate) fn build_auth_logout_output(env_token_present: bool) -> AuthLogoutOutput {
    if env_token_present {
        AuthLogoutOutput {
            saved_token_cleared: true,
            effective_token_present: true,
            effective_token_source: Some("INLINE_TOKEN".to_string()),
            warning: Some(
                "INLINE_TOKEN is still set; future commands will remain authenticated from the environment."
                    .to_string(),
            ),
        }
    } else {
        AuthLogoutOutput {
            saved_token_cleared: true,
            effective_token_present: false,
            effective_token_source: None,
            warning: None,
        }
    }
}

pub(crate) fn print_auth_logout(output: &AuthLogoutOutput) {
    if let Some(warning) = output.warning.as_deref() {
        println!("Cleared saved token.");
        println!("Warning: {warning}");
    } else {
        println!("Logged out.");
    }
}

pub(crate) fn print_auth_user(user: &proto::User) {
    let name = user_display_name(user);
    println!("Logged in as {} (id {}).", name, user.id);

    if let Some(username) = user.username.as_deref() {
        let trimmed = username.trim();
        if !trimmed.is_empty() {
            println!("username: @{}", trimmed);
        }
    }

    if let Some(email) = user.email.as_deref() {
        let trimmed = email.trim();
        if !trimmed.is_empty() {
            println!("email: {}", trimmed);
        }
    }

    if let Some(phone) = user.phone_number.as_deref() {
        let trimmed = phone.trim();
        if !trimmed.is_empty() {
            println!("phone: {}", trimmed);
        }
    }
}

fn print_auth_error(error: &ApiError) {
    match error {
        ApiError::Api {
            status,
            error,
            error_code,
            description,
        } => {
            let status = status
                .map(|value| format!(" HTTP {value},"))
                .unwrap_or_default();
            let code = error_code
                .map(|value| format!(" code {value},"))
                .unwrap_or_default();
            eprintln!("Could not verify code:{status}{code} {error}. {description}");
        }
        ApiError::Status {
            status,
            message,
            body,
        } => {
            eprintln!("Could not verify code (server status {status}: {message}).");
            if let Some(body) = body {
                eprintln!("Server response: {body}");
            }
        }
        ApiError::Http(err) => {
            eprintln!("Network error while verifying code: {err}");
        }
        ApiError::Io(err) => {
            eprintln!("Local IO error while verifying code: {err}");
        }
        ApiError::Json(err) => {
            eprintln!("Could not decode server response while verifying code: {err}");
        }
    }
}
