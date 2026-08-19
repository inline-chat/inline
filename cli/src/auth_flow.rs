use dialoguer::{Input, Select};
use serde::Serialize;
use std::io::{self, IsTerminal, Read};

use crate::auth::AuthStore;
use crate::errors::CliError;
use crate::identity as client_info;
use crate::mac_app_auth::{self, LoginOutcome};
use crate::output::{self, JsonFormat};
use crate::state::LocalDb;
use crate::{AuthLoginArgs, fetch_me, is_interactive_terminal, user_display_name};
use inline_protocol::proto;
use inline_sdk::api::{ApiClient, ApiError, SendCodeResult, VerifyCodeResult};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AuthLogoutOutput {
    pub(crate) saved_token_cleared: bool,
    pub(crate) effective_token_present: bool,
    pub(crate) effective_token_source: Option<String>,
    pub(crate) warning: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthCodeSentOutput {
    status: &'static str,
    delivery: &'static str,
    existing_user: bool,
    needs_invite_code: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    challenge_token: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthLoginOutput {
    status: &'static str,
    user_id: i64,
    token_saved: bool,
    profile_loaded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    user: Option<proto::User>,
    #[serde(skip_serializing_if = "Option::is_none")]
    warning: Option<String>,
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
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    if !args.mac_app_bootstrap && (args.send_code || args.code.is_some() || args.code_stdin) {
        return handle_inline_protocol_login(
            &args,
            auth_store,
            realtime_url,
            local_db,
            json,
            json_format,
        )
        .await;
    }
    let send_code_only = args.send_code;
    let supplied_code = args.code.clone();
    let code_stdin = args.code_stdin;
    let challenge_token = args.challenge_token.clone();
    let mac_app_bootstrap = args.mac_app_bootstrap;
    let expected_user_id = args.expected_user_id;
    let mut contact = contact_from_args(args)?;

    if mac_app_bootstrap {
        if !json {
            return Err(CliError::invalid_args("--mac-app-bootstrap requires --json").into());
        }

        if expected_user_id.is_some_and(|user_id| user_id <= 0) {
            return Err(CliError::invalid_args("--expected-user-id must be positive").into());
        }

        if let Some(output) =
            verified_existing_saved_login(auth_store, local_db, realtime_url, expected_user_id)
                .await?
        {
            output::print_json(&output, json_format)?;
            return Ok(());
        }

        let device_name = client_info::device_name();
        let device_id = auth_store.device_id()?;
        match mac_app_auth::login_from_parent_app(
            &device_id,
            device_name.as_deref(),
            client_info::client_version(),
            client_info::current_os_version().as_deref(),
        )
        .await?
        {
            LoginOutcome::Token { token, user_id } => {
                ensure_expected_mac_app_user(expected_user_id, user_id)?;
                finish_login_with_token(
                    &token,
                    user_id,
                    auth_store,
                    realtime_url,
                    local_db,
                    true,
                    json_format,
                )
                .await?;
                return Ok(());
            }
            LoginOutcome::Cancelled(detail) => {
                return Err(CliError::mac_app_auth_cancelled(detail).into());
            }
        }
    }

    if challenge_token.is_some() && (send_code_only || (supplied_code.is_none() && !code_stdin)) {
        return Err(
            CliError::invalid_args("--challenge-token requires --code or --code-stdin").into(),
        );
    }

    if send_code_only {
        let current = require_contact(contact.take(), "--send-code")?;
        let device_name = client_info::device_name();
        let device_id = auth_store.device_id()?;
        let auth_metadata = client_info::auth_metadata(&device_id, device_name.as_deref());
        let result = send_code(api, &current, &auth_metadata).await?;
        print_code_sent(&current, result, json, json_format)?;
        return Ok(());
    }

    if supplied_code.is_some() || code_stdin {
        let current = require_contact(contact.take(), "--code/--code-stdin")?;
        if challenge_token.is_some() && !matches!(current, Contact::Email(_)) {
            return Err(
                CliError::invalid_args("--challenge-token can only be used with --email").into(),
            );
        }
        let code = match supplied_code {
            Some(code) => normalize_code(code)?,
            None => read_code_from_stdin()?,
        };
        let device_name = client_info::device_name();
        let device_id = auth_store.device_id()?;
        let auth_metadata = client_info::auth_metadata(&device_id, device_name.as_deref());
        let result = verify_code(
            api,
            &current,
            &code,
            challenge_token.as_deref(),
            &auth_metadata,
        )
        .await?;
        finish_login(
            result,
            auth_store,
            realtime_url,
            local_db,
            json,
            json_format,
        )
        .await?;
        return Ok(());
    }

    if json {
        return Err(CliError::interactive_required(
            "choose an explicit non-interactive login phase",
            vec![
                "inline auth login --email you@example.com --send-code --json".to_string(),
                "inline auth login --email you@example.com --code 123456 --challenge-token TOKEN --json".to_string(),
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
                "inline auth login --email you@example.com --send-code --json".to_string(),
                "inline auth login --email you@example.com --code 123456 --challenge-token TOKEN --json".to_string(),
                "INLINE_TOKEN=... inline auth me --json".to_string(),
            ],
        )
        .into());
    }

    let device_name = client_info::device_name();
    let device_id = auth_store.device_id()?;
    let auth_metadata = client_info::auth_metadata(&device_id, device_name.as_deref());

    if contact.is_none() && mac_app_auth::supporting_app_available() {
        let options = ["Continue with Inline for Mac", "Use email or phone"];
        let selection = Select::new().items(&options).default(0).interact()?;
        if selection == 0 {
            println!("Opening Inline for Mac for approval…");
            match mac_app_auth::login(
                &device_id,
                device_name.as_deref(),
                client_info::client_version(),
                client_info::current_os_version().as_deref(),
            )
            .await
            {
                Ok(LoginOutcome::Token { token, user_id }) => {
                    finish_login_with_token(
                        &token,
                        user_id,
                        auth_store,
                        realtime_url,
                        local_db,
                        false,
                        json_format,
                    )
                    .await?;
                    return Ok(());
                }
                Ok(LoginOutcome::Cancelled(detail)) => {
                    eprintln!(
                        "Inline for Mac did not approve the request.{}",
                        detail
                            .filter(|value| !value.trim().is_empty())
                            .map(|value| format!(" {value}"))
                            .unwrap_or_default()
                    );
                }
                Err(error) => {
                    eprintln!("Could not use Inline for Mac: {error}");
                }
            }
            println!("Continue with email or phone instead.");
        }
    }

    loop {
        let current = match contact.take() {
            Some(value) => value,
            None => prompt_contact()?,
        };

        let email_challenge_token = send_code(api, &current, &auth_metadata)
            .await?
            .challenge_token;

        loop {
            let code = prompt_code()?;
            let result = verify_code(
                api,
                &current,
                &code,
                email_challenge_token.as_deref(),
                &auth_metadata,
            )
            .await;

            match result {
                Ok(result) => {
                    finish_login(
                        result,
                        auth_store,
                        realtime_url,
                        local_db,
                        false,
                        json_format,
                    )
                    .await?;
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

async fn handle_inline_protocol_login(
    args: &AuthLoginArgs,
    auth_store: &AuthStore,
    realtime_url: &str,
    local_db: &LocalDb,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let contact = require_contact(contact_from_args(args.clone())?, "Inline Protocol login")?;
    let v3_url = format!("{}/v3", realtime_url.trim_end_matches('/'));
    if args.send_code {
        let keys = client_info::resolve_inline_protocol_public_ring()?;
        let mut connection =
            client_info::connect_inline_protocol_fresh(&v3_url, keys, false).await?;
        let identifier = match contact {
            Contact::Email(email) => proto::auth_begin_request::Identifier::Email(email),
            Contact::Phone(phone) => proto::auth_begin_request::Identifier::PhoneNumber(phone),
        };
        let challenge = connection
            .auth_begin(proto::AuthBeginRequest {
                identifier: Some(identifier),
                client: Some(inline_protocol_client_info(auth_store)?),
            })
            .await?;
        auth_store
            .store_inline_protocol_pending(&connection.authorization(), &challenge.challenge_id)?;
        let delivery = if challenge.delivery == proto::auth_begin_result::Delivery::Sms as i32 {
            "sms"
        } else {
            "email"
        };
        let output = AuthCodeSentOutput {
            status: "code_sent",
            delivery,
            existing_user: true,
            needs_invite_code: false,
            challenge_token: None,
        };
        if json {
            output::print_json(&output, json_format)?;
        } else {
            println!("Login code sent by {delivery}.");
            println!("Complete login with --code CODE.");
        }
        return Ok(());
    }

    let code = match args.code.clone() {
        Some(code) => normalize_code(code)?,
        None if args.code_stdin => read_code_from_stdin()?,
        None => {
            return Err(CliError::invalid_args(
                "Inline Protocol login requires --send-code or --code",
            )
            .into());
        }
    };
    let (permanent_authorization, challenge_id) = auth_store
        .load_inline_protocol_pending()?
        .ok_or_else(|| CliError::invalid_args("send a new Inline Protocol login code first"))?;
    let mut permanent =
        client_info::reconnect_inline_protocol(&v3_url, permanent_authorization.clone()).await?;
    let completed = permanent
        .auth_complete(proto::AuthCompleteRequest {
            challenge_id,
            code,
            invite_code: None,
            time_zone: None,
        })
        .await?;
    let authorized = match completed.state {
        Some(proto::auth_complete_result::State::Authorized(value)) => value,
        Some(proto::auth_complete_result::State::InviteRequired(_)) => {
            return Err(CliError::invalid_args("this account requires an invite code").into());
        }
        None => {
            return Err(CliError::invalid_args("authentication returned no account state").into());
        }
    };
    let keys = client_info::resolve_inline_protocol_public_ring()?;
    let mut temporary = client_info::connect_inline_protocol_fresh(&v3_url, keys, true).await?;
    temporary.bind_temporary(&permanent_authorization).await?;
    auth_store.store_inline_protocol_authorizations(
        &permanent_authorization,
        &temporary.authorization(),
    )?;
    let user = match authorized.user {
        Some(user) => user,
        None => temporary
            .call(proto::GetMeInput {})
            .await?
            .user
            .ok_or_else(|| CliError::unexpected_api_response("getMe", "missing user"))?,
    };
    local_db.set_current_user(user.clone())?;
    let output = AuthLoginOutput {
        status: "authenticated",
        user_id: user.id,
        token_saved: false,
        profile_loaded: true,
        user: Some(user),
        warning: None,
    };
    if json {
        output::print_json(&output, json_format)?;
    } else if let Some(user) = output.user.as_ref() {
        println!("Welcome, {}.", user_display_name(user));
    }
    Ok(())
}

fn inline_protocol_client_info(
    auth_store: &AuthStore,
) -> Result<proto::ClientInfo, Box<dyn std::error::Error>> {
    Ok(proto::ClientInfo {
        device_id: Some(auth_store.device_id()?),
        client_type: Some(client_info::client_type().into()),
        client_version: Some(client_info::client_version().into()),
        os_version: client_info::current_os_version(),
        device_name: client_info::device_name(),
    })
}

fn ensure_expected_mac_app_user(
    expected_user_id: Option<i64>,
    actual_user_id: i64,
) -> Result<(), CliError> {
    if expected_user_id.is_some_and(|expected| expected != actual_user_id) {
        return Err(CliError::mac_app_auth_user_mismatch());
    }
    Ok(())
}

fn existing_saved_login(
    auth_store: &AuthStore,
    local_db: &LocalDb,
) -> Result<Option<AuthLoginOutput>, Box<dyn std::error::Error>> {
    let Some(token) = auth_store.load_saved_token()? else {
        return Ok(None);
    };
    let Some(user_id) = token_user_id(&token) else {
        return Ok(None);
    };
    let user = local_db
        .load()
        .ok()
        .and_then(|state| state.current_user)
        .filter(|user| user.id == user_id);

    Ok(Some(AuthLoginOutput {
        status: "authenticated",
        user_id,
        token_saved: true,
        profile_loaded: user.is_some(),
        user,
        warning: None,
    }))
}

async fn verified_existing_saved_login(
    auth_store: &AuthStore,
    local_db: &LocalDb,
    realtime_url: &str,
    expected_user_id: Option<i64>,
) -> Result<Option<AuthLoginOutput>, Box<dyn std::error::Error>> {
    let Some(existing) = existing_saved_login(auth_store, local_db)? else {
        return Ok(None);
    };
    if expected_user_id.is_some_and(|expected| expected != existing.user_id) {
        return Ok(None);
    }
    let Some(token) = auth_store.load_saved_token()? else {
        return Ok(None);
    };
    let Ok(mut realtime) = client_info::connect_realtime(realtime_url, &token).await else {
        return Ok(None);
    };
    let Ok(user) = fetch_me(&mut realtime).await else {
        return Ok(None);
    };
    if user.id != existing.user_id || expected_user_id.is_some_and(|expected| expected != user.id) {
        return Ok(None);
    }

    let warning = local_db
        .set_current_user(user.clone())
        .err()
        .map(|_| "Authenticated, but the local profile cache could not be refreshed.".to_string());
    Ok(Some(AuthLoginOutput {
        status: "authenticated",
        user_id: user.id,
        token_saved: true,
        profile_loaded: true,
        user: Some(user),
        warning,
    }))
}

fn token_user_id(token: &str) -> Option<i64> {
    let (user_id, credential) = token.trim().split_once(':')?;
    if user_id.is_empty() || !user_id.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let random = credential.strip_prefix("IN")?;
    if random.len() != 32 || !random.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        return None;
    }
    user_id.parse().ok().filter(|user_id| *user_id > 0)
}

fn require_contact(
    contact: Option<Contact>,
    phase: &str,
) -> Result<Contact, Box<dyn std::error::Error>> {
    contact.ok_or_else(|| {
        CliError::invalid_args(format!(
            "{phase} requires exactly one of --email or --phone"
        ))
        .into()
    })
}

async fn send_code(
    api: &ApiClient,
    contact: &Contact,
    auth_metadata: &inline_sdk::client_info::AuthMetadata,
) -> Result<SendCodeResult, ApiError> {
    match contact {
        Contact::Email(email) => api.send_email_code(email, auth_metadata).await,
        Contact::Phone(phone) => api.send_sms_code(phone, auth_metadata).await,
    }
}

async fn verify_code(
    api: &ApiClient,
    contact: &Contact,
    code: &str,
    challenge_token: Option<&str>,
    auth_metadata: &inline_sdk::client_info::AuthMetadata,
) -> Result<VerifyCodeResult, ApiError> {
    match contact {
        Contact::Email(email) => {
            api.verify_email_code(email, code, challenge_token, auth_metadata)
                .await
        }
        Contact::Phone(phone) => api.verify_sms_code(phone, code, auth_metadata).await,
    }
}

fn print_code_sent(
    contact: &Contact,
    result: SendCodeResult,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let delivery = match contact {
        Contact::Email(_) => "email",
        Contact::Phone(_) => "phone",
    };
    let output = AuthCodeSentOutput {
        status: "code_sent",
        delivery,
        existing_user: result.existing_user,
        needs_invite_code: result.needs_invite_code,
        challenge_token: result.challenge_token,
    };
    if json {
        output::print_json(&output, json_format)?;
        return Ok(());
    }

    println!("Login code sent by {delivery}.");
    if let Some(challenge_token) = output.challenge_token.as_deref() {
        println!("Email challenge token: {challenge_token}");
    }
    println!(
        "Complete login with --code CODE{}.",
        if output.challenge_token.is_some() {
            " --challenge-token TOKEN"
        } else {
            ""
        }
    );
    Ok(())
}

async fn finish_login(
    result: VerifyCodeResult,
    auth_store: &AuthStore,
    realtime_url: &str,
    local_db: &LocalDb,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    finish_login_with_token(
        &result.token,
        result.user_id,
        auth_store,
        realtime_url,
        local_db,
        json,
        json_format,
    )
    .await
}

async fn finish_login_with_token(
    token: &str,
    user_id: i64,
    auth_store: &AuthStore,
    realtime_url: &str,
    local_db: &LocalDb,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    auth_store.store_token(token)?;

    let mut warnings = Vec::new();
    if let Err(error) = local_db.clear_current_user() {
        warnings.push(format!(
            "Authenticated, but failed to clear the previously cached profile: {error}"
        ));
    }

    let user = match client_info::connect_realtime(realtime_url, token).await {
        Ok(mut realtime) => match fetch_me(&mut realtime).await {
            Ok(me) => match local_db.set_current_user(me.clone()) {
                Ok(()) => {
                    warnings.clear();
                    Some(me)
                }
                Err(error) => {
                    warnings.push(format!(
                        "Authenticated, but failed to cache profile: {error}"
                    ));
                    Some(me)
                }
            },
            Err(error) => {
                warnings.push(format!(
                    "Authenticated, but failed to load profile: {error}"
                ));
                None
            }
        },
        Err(error) => {
            warnings.push(format!(
                "Authenticated, but failed to connect for profile loading: {error}"
            ));
            None
        }
    };
    let warning = (!warnings.is_empty()).then(|| warnings.join(" "));

    let output = AuthLoginOutput {
        status: "authenticated",
        user_id,
        token_saved: true,
        profile_loaded: user.is_some(),
        user,
        warning,
    };

    if json {
        output::print_json(&output, json_format)?;
    } else if let Some(user) = output.user.as_ref() {
        println!("Welcome, {}.", user_display_name(user));
        if let Some(warning) = output.warning.as_deref() {
            eprintln!("{warning}");
        }
    } else {
        println!("Logged in as user {}.", output.user_id);
        if let Some(warning) = output.warning.as_deref() {
            eprintln!("{warning}");
        }
    }
    Ok(())
}

fn normalize_code(code: String) -> Result<String, Box<dyn std::error::Error>> {
    let code = code.trim().to_string();
    if code.is_empty() {
        return Err(CliError::invalid_args("Login code cannot be empty").into());
    }
    Ok(code)
}

fn read_code_from_stdin() -> Result<String, Box<dyn std::error::Error>> {
    if io::stdin().is_terminal() {
        return Err(
            CliError::invalid_args("--code-stdin requires a pipe or redirected stdin").into(),
        );
    }
    let mut code = String::new();
    io::stdin().read_to_string(&mut code)?;
    normalize_code(code)
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
        let email = email.trim().to_string();
        if email.is_empty() {
            return Err(CliError::invalid_args("--email cannot be empty").into());
        }
        return Ok(Some(Contact::Email(email)));
    }

    if let Some(phone) = args.phone {
        let phone = phone.trim().to_string();
        if phone.is_empty() {
            return Err(CliError::invalid_args("--phone cannot be empty").into());
        }
        return Ok(Some(Contact::Phone(phone)));
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
        ApiError::InvalidBaseUrl { message, .. } => {
            eprintln!("Invalid Inline API base URL: {message}");
        }
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
        _ => {
            eprintln!("Could not verify code: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::fs;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn non_interactive_email_login_sends_then_verifies_without_printing_token() {
        let root = tempfile::tempdir().unwrap();
        let secrets_path = root.path().join("secrets.json");
        let state_path = root.path().join("state.json");

        let (api_url, send_request) = serve_json(
            r#"{"ok":true,"result":{"existingUser":true,"needsInviteCode":false,"challengeToken":"challenge-123"}}"#,
        )
        .await;
        let auth_store = AuthStore::new(secrets_path.clone(), api_url.clone());
        let local_db = LocalDb::new(state_path.clone(), api_url.clone());
        handle_login(
            AuthLoginArgs {
                email: Some("agent@example.com".to_string()),
                phone: None,
                send_code: true,
                code: None,
                code_stdin: false,
                challenge_token: None,
                mac_app_bootstrap: false,
                expected_user_id: None,
            },
            &ApiClient::try_new(api_url).unwrap(),
            &auth_store,
            "ws://127.0.0.1:9/realtime",
            &local_db,
            true,
            JsonFormat::Compact,
        )
        .await
        .unwrap();
        let send_request = send_request.await.unwrap();
        assert!(send_request.starts_with("POST /v1/sendEmailCode "));
        assert!(send_request.contains("agent@example.com"));

        let (api_url, verify_request) =
            serve_json(r#"{"ok":true,"result":{"userId":42,"token":"test-bearer-token"}}"#).await;
        let auth_store = AuthStore::new(secrets_path.clone(), api_url.clone());
        let local_db = LocalDb::new(state_path.clone(), api_url.clone());
        handle_login(
            AuthLoginArgs {
                email: Some("agent@example.com".to_string()),
                phone: None,
                send_code: false,
                code: Some("123456".to_string()),
                code_stdin: false,
                challenge_token: Some("challenge-123".to_string()),
                mac_app_bootstrap: false,
                expected_user_id: None,
            },
            &ApiClient::try_new(api_url).unwrap(),
            &auth_store,
            "ws://127.0.0.1:9/realtime",
            &local_db,
            true,
            JsonFormat::Compact,
        )
        .await
        .unwrap();
        let verify_request = verify_request.await.unwrap();
        assert!(verify_request.starts_with("POST /v1/verifyEmailCode "));
        assert!(verify_request.contains("challenge-123"));
        assert!(verify_request.contains("123456"));

        let secrets: Value =
            serde_json::from_str(&fs::read_to_string(secrets_path).unwrap()).unwrap();
        assert_eq!(secrets["token"], "test-bearer-token");
        let state: Value = serde_json::from_str(&fs::read_to_string(state_path).unwrap()).unwrap();
        assert!(state["currentUser"].is_null());

        let output = AuthLoginOutput {
            status: "authenticated",
            user_id: 42,
            token_saved: true,
            profile_loaded: false,
            user: None,
            warning: None,
        };
        let output = serde_json::to_value(output).unwrap();
        assert!(output.get("token").is_none());
        assert_eq!(output["status"], "authenticated");
    }

    #[test]
    fn existing_saved_login_skips_bootstrap_without_cached_profile() {
        let root = tempfile::tempdir().unwrap();
        let auth_store = AuthStore::new(
            root.path().join("secrets.json"),
            "https://api.inline.chat/v1".to_string(),
        );
        let local_db = LocalDb::new(
            root.path().join("state.json"),
            "https://api.inline.chat/v1".to_string(),
        );
        auth_store
            .store_token("42:IN0123456789abcdefghijklmnopqrstuv")
            .unwrap();

        let output = existing_saved_login(&auth_store, &local_db)
            .unwrap()
            .expect("existing login");

        assert_eq!(output.status, "authenticated");
        assert_eq!(output.user_id, 42);
        assert!(output.token_saved);
        assert!(!output.profile_loaded);
        assert!(output.user.is_none());
    }

    #[test]
    fn mac_app_handoff_must_match_the_expected_user_before_token_persistence() {
        assert!(ensure_expected_mac_app_user(Some(42), 42).is_ok());
        assert!(ensure_expected_mac_app_user(None, 42).is_ok());
        let error = ensure_expected_mac_app_user(Some(42), 43).expect_err("mismatch");
        assert_eq!(error.code, "mac_app_auth_user_mismatch");
    }

    #[test]
    fn malformed_saved_token_continues_to_authentication() {
        let root = tempfile::tempdir().unwrap();
        let auth_store = AuthStore::new(
            root.path().join("secrets.json"),
            "https://api.inline.chat/v1".to_string(),
        );
        let local_db = LocalDb::new(
            root.path().join("state.json"),
            "https://api.inline.chat/v1".to_string(),
        );
        auth_store.store_token("not-an-inline-token").unwrap();

        assert!(
            existing_saved_login(&auth_store, &local_db)
                .unwrap()
                .is_none()
        );
    }

    async fn serve_json(response_body: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let request = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut chunk = [0_u8; 1024];
                let read = stream.read(&mut chunk).await.unwrap();
                assert!(read > 0, "client closed before completing request");
                request.extend_from_slice(&chunk[..read]);
                if let Some(header_end) = request
                    .windows(4)
                    .position(|window| window == b"\r\n\r\n")
                    .map(|position| position + 4)
                {
                    let headers = String::from_utf8_lossy(&request[..header_end]);
                    let content_length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .and_then(|value| value.trim().parse::<usize>().ok())
                        })
                        .unwrap_or(0);
                    if request.len() >= header_end + content_length {
                        break;
                    }
                }
            }

            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8(request).unwrap()
        });
        (format!("http://{address}/v1"), request)
    }
}
