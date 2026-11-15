//! ChatGPT credentials for Dot calls.
//!
//! The bridge never stores a ChatGPT credential. It asks a [`TokenSource`]
//! for a bearer token, keeps it in memory, and asks again before expiry or
//! after a 401. The default source is the local Codex app-server, which owns
//! `codex login` and its refresh.

use std::fmt;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

use crate::error::{DotsError, DotsResult};

/// Boxed future returned by [`TokenSource`].
pub type TokenFuture<'a> = Pin<Box<dyn Future<Output = DotsResult<AccessToken>> + Send + 'a>>;

/// A ChatGPT bearer token. `Debug` and `Display` never show the value.
#[derive(Clone, PartialEq, Eq)]
pub struct AccessToken(String);

impl AccessToken {
    /// Wraps a raw bearer token.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The raw value, for building the `Authorization` header only.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Identity claims carried in the token's JWT payload.
    pub fn identity(&self) -> DotsResult<Identity> {
        Identity::from_jwt(&self.0)
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("AccessToken(<redacted>)")
    }
}

/// Account identity from the ChatGPT access token.
#[derive(Clone, PartialEq, Eq)]
pub struct Identity {
    /// `chatgpt_account_id`; sent as `ChatGPT-Account-Id`.
    pub account_id: String,
    /// `chatgpt_user_id`.
    pub user_id: String,
    /// `chatgpt_account_user_id`; the sender id on messages the owner writes.
    pub account_user_id: String,
    /// `chatgpt_plan_type`, when present.
    pub plan_type: Option<String>,
    /// Token expiry.
    pub expires_at: SystemTime,
}

impl fmt::Debug for Identity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Identity")
            .field("account_id", &crate::redact_id(&self.account_id))
            .field("plan_type", &self.plan_type)
            .field("expires_at", &self.expires_at)
            .finish_non_exhaustive()
    }
}

#[derive(Deserialize)]
struct JwtPayload {
    exp: Option<u64>,
    #[serde(rename = "https://api.openai.com/auth", default)]
    auth: Option<AuthClaim>,
}

#[derive(Deserialize)]
struct AuthClaim {
    chatgpt_account_id: Option<String>,
    chatgpt_user_id: Option<String>,
    chatgpt_account_user_id: Option<String>,
    chatgpt_plan_type: Option<String>,
}

impl Identity {
    /// Decodes the unverified JWT payload. ChatGPT verifies the signature;
    /// the bridge only needs the routing claims.
    pub fn from_jwt(token: &str) -> DotsResult<Self> {
        let payload = token
            .split('.')
            .nth(1)
            .ok_or(DotsError::InvalidToken("not a JWT"))?;
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(payload.trim_end_matches('='))
            .map_err(|_| DotsError::InvalidToken("payload is not base64url"))?;
        let payload: JwtPayload = serde_json::from_slice(&bytes)
            .map_err(|_| DotsError::InvalidToken("payload is not JSON"))?;
        let auth = payload
            .auth
            .ok_or(DotsError::InvalidToken("missing ChatGPT auth claim"))?;
        let nonempty = |value: Option<String>, what: &'static str| {
            value
                .filter(|value| !value.is_empty())
                .ok_or(DotsError::InvalidToken(what))
        };
        Ok(Self {
            account_id: nonempty(auth.chatgpt_account_id, "missing chatgpt_account_id")?,
            user_id: nonempty(auth.chatgpt_user_id, "missing chatgpt_user_id")?,
            account_user_id: nonempty(
                auth.chatgpt_account_user_id,
                "missing chatgpt_account_user_id",
            )?,
            plan_type: auth.chatgpt_plan_type,
            expires_at: UNIX_EPOCH
                + Duration::from_secs(payload.exp.ok_or(DotsError::InvalidToken("missing exp"))?),
        })
    }

    /// Time left before expiry; zero once expired.
    pub fn remaining(&self) -> Duration {
        self.expires_at
            .duration_since(SystemTime::now())
            .unwrap_or_default()
    }
}

/// Supplies ChatGPT bearer tokens on demand.
pub trait TokenSource: Send + Sync {
    /// Returns a token. `force_refresh` asks the source to mint a new one,
    /// used after ChatGPT rejected the current token with 401.
    fn token(&self, force_refresh: bool) -> TokenFuture<'_>;
}

/// A fixed token, for tests and for callers that manage refresh themselves.
pub struct StaticTokenSource(pub AccessToken);

impl TokenSource for StaticTokenSource {
    fn token(&self, _force_refresh: bool) -> TokenFuture<'_> {
        let token = self.0.clone();
        Box::pin(async move { Ok(token) })
    }
}

/// Reads the ChatGPT token from a short-lived `codex app-server` process.
///
/// Each call spawns the app-server on stdio, sends `initialize`,
/// `initialized`, then `getAuthStatus {includeToken: true, refreshToken}`,
/// and exits. The app-server owns `~/.codex/auth.json` and its refresh; the
/// bridge never opens that file.
#[derive(Clone)]
pub struct CodexAppServerTokenSource {
    executable: PathBuf,
    timeout: Duration,
}

impl fmt::Debug for CodexAppServerTokenSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CodexAppServerTokenSource")
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

impl CodexAppServerTokenSource {
    /// Uses the given `codex` executable.
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            timeout: Duration::from_secs(30),
        }
    }

    /// Overrides the whole-exchange timeout (default 30 s).
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    async fn fetch(&self, refresh: bool) -> DotsResult<AccessToken> {
        let mut child = Command::new(&self.executable)
            .arg("app-server")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| DotsError::Codex("could not start `codex app-server`".into()))?;
        let mut stdin = child.stdin.take().expect("piped stdin");
        let mut lines = BufReader::new(child.stdout.take().expect("piped stdout")).lines();

        let exchange = async {
            write_line(
                &mut stdin,
                &json!({
                    "method": "initialize",
                    "id": 1,
                    "params": {"clientInfo": {
                        "name": "inline_dots_bridge",
                        "title": "Inline Dots bridge",
                        "version": env!("CARGO_PKG_VERSION"),
                    }},
                }),
            )
            .await?;
            read_response(&mut lines, 1).await?;
            write_line(&mut stdin, &json!({"method": "initialized"})).await?;
            write_line(
                &mut stdin,
                &json!({
                    "method": "getAuthStatus",
                    "id": 2,
                    "params": {"includeToken": true, "refreshToken": refresh},
                }),
            )
            .await?;
            read_response(&mut lines, 2).await
        };
        let result = tokio::time::timeout(self.timeout, exchange)
            .await
            .map_err(|_| DotsError::Codex("`codex app-server` did not answer in time".into()))?;
        drop(stdin);
        let _ = child.start_kill();
        let _ = child.wait().await;
        token_from_auth_status(result?)
    }
}

impl TokenSource for CodexAppServerTokenSource {
    fn token(&self, force_refresh: bool) -> TokenFuture<'_> {
        Box::pin(self.fetch(force_refresh))
    }
}

async fn write_line(stdin: &mut tokio::process::ChildStdin, value: &Value) -> DotsResult<()> {
    let mut line = serde_json::to_vec(value).expect("json value serializes");
    line.push(b'\n');
    stdin
        .write_all(&line)
        .await
        .map_err(|_| DotsError::Codex("`codex app-server` closed its input".into()))?;
    stdin
        .flush()
        .await
        .map_err(|_| DotsError::Codex("`codex app-server` closed its input".into()))
}

async fn read_response(
    lines: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    id: u64,
) -> DotsResult<Value> {
    loop {
        let line = lines
            .next_line()
            .await
            .map_err(|_| DotsError::Codex("could not read `codex app-server` output".into()))?
            .ok_or_else(|| DotsError::Codex("`codex app-server` exited early".into()))?;
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if message.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        if let Some(error) = message.get("error") {
            let text = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error");
            return Err(DotsError::Codex(format!(
                "`codex app-server` refused the request: {text}"
            )));
        }
        return Ok(message.get("result").cloned().unwrap_or(Value::Null));
    }
}

/// Interprets a `getAuthStatus` result. Public for tests.
pub fn token_from_auth_status(result: Value) -> DotsResult<AccessToken> {
    let method = result.get("authMethod").and_then(Value::as_str);
    if method != Some("chatgpt") {
        return Err(DotsError::NotSignedIn(match method {
            None => "Codex is not signed in".into(),
            Some(other) => format!("Codex is signed in with `{other}`, not a ChatGPT account"),
        }));
    }
    let token = result
        .get("authToken")
        .and_then(Value::as_str)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| DotsError::NotSignedIn("Codex returned no ChatGPT token".into()))?;
    let token = AccessToken::new(token);
    token.identity()?;
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn fake_jwt(exp: u64) -> String {
        let payload = json!({
            "exp": exp,
            "https://api.openai.com/auth": {
                "chatgpt_account_id": "acct-0000",
                "chatgpt_user_id": "user-0000",
                "chatgpt_account_user_id": "user-0000__acct-0000",
                "chatgpt_plan_type": "plus",
            }
        });
        let encode = |value: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value);
        format!(
            "{}.{}.sig",
            encode(br#"{"alg":"none"}"#),
            encode(payload.to_string().as_bytes())
        )
    }

    #[test]
    fn identity_reads_routing_claims() {
        let identity = Identity::from_jwt(&fake_jwt(4_000_000_000)).unwrap();
        assert_eq!(identity.account_id, "acct-0000");
        assert_eq!(identity.account_user_id, "user-0000__acct-0000");
        assert_eq!(identity.plan_type.as_deref(), Some("plus"));
        assert!(identity.remaining() > Duration::from_secs(3600));
    }

    #[test]
    fn identity_rejects_tokens_without_claims() {
        assert!(Identity::from_jwt("abc").is_err());
        let encode = |value: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value);
        let token = format!("x.{}.y", encode(br#"{"exp":1}"#));
        assert!(matches!(
            Identity::from_jwt(&token),
            Err(DotsError::InvalidToken(_))
        ));
    }

    #[test]
    fn auth_status_requires_chatgpt_method() {
        let api_key = json!({"authMethod": "apikey", "authToken": "sk-x"});
        assert!(matches!(
            token_from_auth_status(api_key),
            Err(DotsError::NotSignedIn(_))
        ));
        let none = json!({"authMethod": null, "authToken": null});
        assert!(matches!(
            token_from_auth_status(none),
            Err(DotsError::NotSignedIn(_))
        ));
        let ok = json!({"authMethod": "chatgpt", "authToken": fake_jwt(4_000_000_000)});
        assert!(token_from_auth_status(ok).is_ok());
    }

    #[test]
    fn debug_never_shows_secrets() {
        let token = AccessToken::new(fake_jwt(4_000_000_000));
        assert_eq!(format!("{token:?}"), "AccessToken(<redacted>)");
        let identity = token.identity().unwrap();
        assert!(!format!("{identity:?}").contains("acct-0000"));
    }
}
