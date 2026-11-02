//! Skills installed for the harness behind this bot: what the Skilled Agents
//! picker and `/skill-name` offer.
//!
//! Each harness finds its own skills. Codex and Amp report theirs; Claude and
//! OpenCode are read from the folders they document.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use inline_agent_bridge::harness::{CatalogScope, HarnessDriver};
use inline_protocol::proto;
use serde::Deserialize;
use serde_json::{Value, json};

use super::render::Vocabulary;
use super::runtime::INLINE_COMMANDS;

/// Picked up without restarting the bridge after this long.
const REFRESH: Duration = Duration::from_secs(5 * 60);
const AMP_LIST_TIMEOUT: Duration = Duration::from_secs(20);
const PUBLISH_TIMEOUT: Duration = Duration::from_secs(20);
// Server limits, from `bot.skillsShared.ts` and `bot.commandsShared.ts`.
const SKILL_LIMIT: usize = 250;
const SKILL_KEY_LIMIT: usize = 256;
const SKILL_DESCRIPTION_LIMIT: usize = 2_000;
const COMMAND_LIMIT: usize = 100;
const COMMAND_NAME_LIMIT: usize = 32;
const COMMAND_DESCRIPTION_LIMIT: usize = 256;
const SKILL_FILE_LIMIT: u64 = 256 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(crate) struct Skill {
    #[serde(rename = "name")]
    pub(crate) key: String,
    #[serde(default)]
    pub(crate) description: Option<String>,
}

impl Skill {
    fn new(key: &str, description: Option<&str>) -> Option<Self> {
        let key = key.trim();
        (!key.is_empty() && key.chars().count() <= SKILL_KEY_LIMIT).then(|| Self {
            key: key.to_owned(),
            description: description
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(|text| truncated(text, SKILL_DESCRIPTION_LIMIT)),
        })
    }

    /// Whether `/name` means this skill. The command menu only takes `_`, so
    /// `gh-fix-ci` is offered as `/gh_fix_ci`; both spellings work.
    pub(crate) fn answers_to(&self, name: &str) -> bool {
        normalized_command(&self.key) == normalized_command(name)
    }
}

fn truncated(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

fn normalized_command(name: &str) -> String {
    name.to_ascii_lowercase().replace('-', "_")
}

/// Text for the harness that runs `key` on `task`. Only known skills and
/// bot-manager configuration get here, never a name someone just typed.
pub(crate) fn activation_text(vocabulary: Vocabulary, key: &str, task: &str) -> String {
    let task = task.trim();
    match (vocabulary, task.is_empty()) {
        // Codex loads a skill when the prompt mentions it this way.
        (Vocabulary::Codex, true) => format!("${key}"),
        (Vocabulary::Codex, false) => format!("${key} {task}"),
        (_, true) => format!("Use the `{key}` skill."),
        (_, false) => format!("Use the `{key}` skill for this request.\n\n{task}"),
    }
}

/// A message for a Skilled Agent, with its instructions and skill applied.
pub(crate) fn specialized_task(
    vocabulary: Vocabulary,
    agent: &proto::BotAgent,
    task: &str,
) -> String {
    let skill_key = agent
        .skill_key
        .as_deref()
        .map(str::trim)
        .filter(|key| !key.is_empty());
    let task = match skill_key {
        Some(key) => activation_text(vocabulary, key, task),
        None => task.to_owned(),
    };
    crate::bridge::runtime::agent_specialization_instruction(agent, &task)
}

/// Lists the harness's skills for a folder.
#[derive(Clone)]
pub(crate) struct SkillCatalog {
    pub(crate) vocabulary: Vocabulary,
    pub(crate) harness: Arc<dyn HarnessDriver>,
    pub(crate) amp_cli: Option<PathBuf>,
}

impl SkillCatalog {
    /// `None` when the list could not be read, so a passing failure never
    /// empties the picker.
    pub(crate) async fn list(&self, folder: &Path) -> Option<Vec<Skill>> {
        match self.vocabulary {
            Vocabulary::Codex => {
                let catalog = self
                    .harness
                    .catalog(CatalogScope {
                        folder: Some(folder.to_path_buf()),
                        session: None,
                    })
                    .await
                    .ok()?;
                // Codex always bundles system skills: empty means not read.
                let skills = catalog
                    .skills
                    .iter()
                    .filter_map(|skill| Skill::new(&skill.value, skill.description.as_deref()))
                    .collect::<Vec<_>>();
                (!skills.is_empty()).then(|| bounded(skills))
            }
            Vocabulary::Amp => amp_skills(self.amp_cli.as_deref()?, folder).await,
            Vocabulary::Claude | Vocabulary::OpenCode => {
                let roots = skill_roots(
                    self.vocabulary,
                    folder,
                    std::env::var_os("HOME").map(PathBuf::from).as_deref(),
                    std::env::var_os("CLAUDE_CONFIG_DIR")
                        .filter(|value| !value.is_empty())
                        .map(PathBuf::from)
                        .as_deref(),
                );
                tokio::task::spawn_blocking(move || scan(&roots)).await.ok()
            }
        }
    }
}

fn bounded(mut skills: Vec<Skill>) -> Vec<Skill> {
    skills.sort_by(|left, right| left.key.cmp(&right.key));
    skills.dedup_by(|left, right| left.key == right.key);
    skills.truncate(SKILL_LIMIT);
    skills
}

/// `amp skill list` already applies Amp's own search order and plugins.
async fn amp_skills(amp_cli: &Path, folder: &Path) -> Option<Vec<Skill>> {
    #[derive(Deserialize)]
    struct Listing {
        skills: Vec<Skill>,
    }
    let mut command = tokio::process::Command::new(amp_cli);
    command
        .args(["skill", "list", "--json"])
        .current_dir(folder)
        .env("AMP_SKIP_UPDATE_CHECK", "1")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("INLINE_") {
            command.env_remove(name);
        }
    }
    let output = tokio::time::timeout(AMP_LIST_TIMEOUT, command.output())
        .await
        .ok()?
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let listing: Listing = serde_json::from_slice(&output.stdout).ok()?;
    Some(bounded(
        listing
            .skills
            .iter()
            .filter_map(|skill| Skill::new(&skill.key, skill.description.as_deref()))
            .collect(),
    ))
}

/// Where a harness keeps skills, nearest first: project folders from `folder`
/// up to its git root, then the user's.
fn skill_roots(
    vocabulary: Vocabulary,
    folder: &Path,
    home: Option<&Path>,
    claude_config: Option<&Path>,
) -> Vec<PathBuf> {
    let (project, user): (&[&str], &[&str]) = match vocabulary {
        Vocabulary::OpenCode => (
            &[".opencode/skills", ".claude/skills", ".agents/skills"],
            &[
                ".config/opencode/skills",
                ".claude/skills",
                ".agents/skills",
            ],
        ),
        _ => (&[".claude/skills"], &[".claude/skills"]),
    };
    let mut roots = Vec::new();
    for directory in project_directories(folder) {
        roots.extend(project.iter().map(|path| directory.join(path)));
    }
    for path in user {
        match (claude_config, *path) {
            (Some(config), ".claude/skills") => roots.push(config.join("skills")),
            _ => roots.extend(home.map(|home| home.join(path))),
        }
    }
    let mut seen = HashSet::new();
    roots.retain(|root| seen.insert(root.clone()));
    roots
}

fn project_directories(folder: &Path) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    for directory in folder.ancestors() {
        directories.push(directory.to_path_buf());
        if directory.join(".git").exists() {
            return directories;
        }
    }
    // Outside a repository, only the folder itself is the project.
    directories.truncate(1);
    directories
}

/// Skills under `roots`, each as its nearest root defines it.
fn scan(roots: &[PathBuf]) -> Vec<Skill> {
    let mut skills = Vec::new();
    let mut seen = HashSet::new();
    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            let directory = entry.path();
            let file = directory.join("SKILL.md");
            // Follows links: skills are often linked in from elsewhere.
            let Ok(metadata) = std::fs::metadata(&file) else {
                continue;
            };
            if !metadata.is_file() || metadata.len() > SKILL_FILE_LIMIT {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let folder_name = entry.file_name();
            let Some(skill) = parse_skill(&text, &folder_name.to_string_lossy()) else {
                continue;
            };
            if seen.insert(skill.key.clone()) {
                skills.push(skill);
            }
        }
    }
    bounded(skills)
}

/// `name` and `description` from a `SKILL.md`. The folder names a skill that
/// has no `name`; a file without frontmatter is not a skill.
fn parse_skill(text: &str, folder_name: &str) -> Option<Skill> {
    let mut lines = text.lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    let mut fields: Vec<(&str, String)> = Vec::new();
    for line in lines {
        if line.trim_end() == "---" {
            let field = |wanted: &str| {
                fields
                    .iter()
                    .find(|(key, _)| *key == wanted)
                    .map(|(_, value)| unquoted(value))
                    .filter(|value| !value.is_empty())
            };
            let name = field("name");
            let description = field("description");
            return Skill::new(name.unwrap_or(folder_name), description);
        }
        if line.starts_with([' ', '\t']) {
            // A folded or continued value.
            if let Some((_, value)) = fields.last_mut() {
                if !value.is_empty() {
                    value.push(' ');
                }
                value.push_str(line.trim());
            }
        } else if let Some((key, value)) = line.split_once(':') {
            let value = value.trim();
            let value = if value.starts_with(['>', '|']) {
                ""
            } else {
                value
            };
            fields.push((key.trim(), value.to_owned()));
        }
    }
    None
}

fn unquoted(value: &str) -> &str {
    let value = value.trim();
    for quote in ['"', '\''] {
        if let Some(inner) = value
            .strip_prefix(quote)
            .and_then(|rest| rest.strip_suffix(quote))
        {
            return inner;
        }
    }
    value
}

/// The bot's slash-command menu: its own commands, then skills that fit.
fn command_menu(base: Vec<proto::BotCommand>, skills: &[Skill]) -> Vec<Value> {
    let mut taken = base
        .iter()
        .map(|command| command.command.clone())
        .chain(INLINE_COMMANDS.iter().map(|name| (*name).to_owned()))
        .collect::<HashSet<_>>();
    let mut menu = base
        .iter()
        .map(|command| {
            json!({
                "command": command.command,
                "description": command.description,
                "sort_order": command.sort_order,
            })
        })
        .collect::<Vec<_>>();
    for skill in skills {
        if menu.len() >= COMMAND_LIMIT {
            break;
        }
        let command = normalized_command(&skill.key);
        let valid = command.len() <= COMMAND_NAME_LIMIT
            && command
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if !valid || !taken.insert(command.clone()) {
            continue;
        }
        let description = skill
            .description
            .as_deref()
            .map_or_else(|| format!("Run the {} skill", skill.key), str::to_owned);
        menu.push(json!({
            "command": command,
            "description": truncated(&description, COMMAND_DESCRIPTION_LIMIT).trim_end(),
            "sort_order": menu.len(),
        }));
    }
    menu
}

fn skills_body(skills: &[Skill]) -> Value {
    let skills = skills
        .iter()
        .enumerate()
        .map(|(index, skill)| {
            let mut body = json!({
                "key": skill.key,
                "name": skill.key,
                "sort_order": index,
            });
            if let Some(description) = &skill.description {
                body["description"] = json!(description);
            }
            body
        })
        .collect::<Vec<_>>();
    json!({ "skills": skills })
}

/// The Bot API sits beside the versioned API, not under it.
fn bot_method_url(api_base_url: &str, method: &str) -> String {
    let base = api_base_url.trim_end_matches('/');
    let base = base.strip_suffix("/v1").unwrap_or(base);
    format!("{base}/bot/{method}")
}

/// Keeps what the apps offer for this bot in step with what is installed.
#[derive(Clone)]
pub(crate) struct SkillPublisher {
    pub(crate) catalog: SkillCatalog,
    pub(crate) folder: PathBuf,
    pub(crate) provider_id: String,
    pub(crate) api_base_url: String,
    pub(crate) bot_token: String,
}

impl SkillPublisher {
    pub(crate) fn spawn(self) -> AbortOnDrop {
        AbortOnDrop(tokio::spawn(self.keep_published()))
    }

    async fn keep_published(self) {
        let mut published = None;
        loop {
            if let Some(skills) = self.catalog.list(&self.folder).await
                && published.as_ref() != Some(&skills)
            {
                match self.publish(&skills).await {
                    Ok(()) => published = Some(skills),
                    Err(error) => {
                        log::warn!(target: "inline::bridge::v2", "skill sync failed: {error}");
                    }
                }
            }
            tokio::time::sleep(REFRESH).await;
        }
    }

    async fn publish(&self, skills: &[Skill]) -> Result<(), String> {
        publish_to_bot(
            &self.api_base_url,
            &self.bot_token,
            &self.provider_id,
            skills,
        )
        .await
    }
}

async fn publish_to_bot(
    api_base_url: &str,
    bot_token: &str,
    provider_id: &str,
    skills: &[Skill],
) -> Result<(), String> {
    let base = crate::bridge::setup::agent_command_catalog(provider_id);
    let client = crate::identity::http_client_builder()
        .timeout(PUBLISH_TIMEOUT)
        .build()
        .map_err(|error| error.to_string())?;
    for (method, body) in [
        ("setMySkills", skills_body(skills)),
        (
            "setMyCommands",
            json!({ "commands": command_menu(base, skills) }),
        ),
    ] {
        let response = client
            .post(bot_method_url(api_base_url, method))
            .bearer_auth(bot_token)
            .json(&body)
            .send()
            .await
            .map_err(|error| error.without_url().to_string())?;
        let status = response.status();
        if !status.is_success() {
            return Err(format!("{method} returned {status}"));
        }
        let envelope: Value = response
            .json()
            .await
            .map_err(|error| error.without_url().to_string())?;
        if envelope.get("ok").and_then(Value::as_bool) == Some(false) {
            return Err(format!("{method} was rejected"));
        }
    }
    Ok(())
}

pub(crate) struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn skill(key: &str, description: Option<&str>) -> Skill {
        Skill::new(key, description).unwrap()
    }

    fn write_skill(root: &Path, folder: &str, text: &str) {
        let directory = root.join(folder);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("SKILL.md"), text).unwrap();
    }

    #[test]
    fn parses_frontmatter_forms() {
        assert_eq!(
            parse_skill(
                "---\nname: deploy\ndescription: Ships it\n---\nbody",
                "folder"
            ),
            Some(skill("deploy", Some("Ships it")))
        );
        assert_eq!(
            parse_skill(
                "---\nname: \"quoted\"\ndescription: >\n  Folded over\n  two lines\nlicense: MIT\n---\n",
                "folder"
            ),
            Some(skill("quoted", Some("Folded over two lines")))
        );
        assert_eq!(
            parse_skill("---\ndescription: 'Colon: kept'\n---\n", "from-folder"),
            Some(skill("from-folder", Some("Colon: kept")))
        );
        assert_eq!(parse_skill("# Just markdown\n", "folder"), None);
        assert_eq!(parse_skill("---\nname: unterminated\n", "folder"), None);
    }

    #[test]
    fn scan_prefers_the_nearest_root_and_skips_what_is_not_a_skill() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("project");
        let user = dir.path().join("user");
        write_skill(
            &project,
            "shared",
            "---\nname: shared\ndescription: Project\n---\n",
        );
        write_skill(
            &user,
            "shared",
            "---\nname: shared\ndescription: User\n---\n",
        );
        write_skill(&user, "alpha", "---\nname: alpha\n---\n");
        write_skill(&user, "plain", "no frontmatter");
        std::fs::create_dir_all(user.join("empty")).unwrap();
        std::fs::write(user.join("loose-file"), "x").unwrap();

        let missing = dir.path().join("missing");
        assert_eq!(
            scan(&[missing, project, user]),
            vec![skill("alpha", None), skill("shared", Some("Project"))]
        );
    }

    #[test]
    fn roots_follow_each_harness_and_stop_at_the_git_root() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let nested = repo.join("apps/web");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let home = dir.path().join("home");

        assert_eq!(
            skill_roots(Vocabulary::Claude, &nested, Some(&home), None),
            vec![
                nested.join(".claude/skills"),
                repo.join("apps/.claude/skills"),
                repo.join(".claude/skills"),
                home.join(".claude/skills"),
            ]
        );
        let config = dir.path().join("config");
        assert_eq!(
            skill_roots(Vocabulary::Claude, &repo, Some(&home), Some(&config)),
            vec![repo.join(".claude/skills"), config.join("skills")]
        );
        let outside = dir.path().join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        assert_eq!(
            skill_roots(Vocabulary::OpenCode, &outside, Some(&home), None),
            vec![
                outside.join(".opencode/skills"),
                outside.join(".claude/skills"),
                outside.join(".agents/skills"),
                home.join(".config/opencode/skills"),
                home.join(".claude/skills"),
                home.join(".agents/skills"),
            ]
        );
    }

    #[test]
    fn activation_uses_each_harness_form() {
        assert_eq!(
            activation_text(Vocabulary::Codex, "fix-ci", " the build "),
            "$fix-ci the build"
        );
        assert_eq!(activation_text(Vocabulary::Codex, "fix-ci", ""), "$fix-ci");
        assert_eq!(
            activation_text(Vocabulary::Amp, "fix-ci", "the build"),
            "Use the `fix-ci` skill for this request.\n\nthe build"
        );
        assert_eq!(
            activation_text(Vocabulary::OpenCode, "fix-ci", ""),
            "Use the `fix-ci` skill."
        );
    }

    #[test]
    fn skilled_agents_activate_their_skill() {
        let agent = proto::BotAgent {
            name: "CI".to_owned(),
            skill_key: Some(" fix-ci ".to_owned()),
            instructions: Some("Be brief.".to_owned()),
            ..Default::default()
        };
        let codex = specialized_task(Vocabulary::Codex, &agent, "the build");
        assert!(codex.contains("Be brief."));
        assert!(codex.ends_with("Current task:\n$fix-ci the build"));
        let plain = proto::BotAgent {
            name: "Plain".to_owned(),
            ..Default::default()
        };
        assert!(specialized_task(Vocabulary::Claude, &plain, "hello").ends_with("\nhello"));
    }

    #[test]
    fn commands_answer_to_either_spelling() {
        let fix = skill("gh-fix-ci", None);
        for name in ["gh-fix-ci", "gh_fix_ci", "GH_FIX_CI"] {
            assert!(fix.answers_to(name), "{name}");
        }
        assert!(!fix.answers_to("gh-fix"));
    }

    #[test]
    fn menu_keeps_bot_commands_and_only_adds_valid_new_skills() {
        let base = vec![proto::BotCommand {
            command: "help".to_owned(),
            description: "Show agent commands".to_owned(),
            sort_order: Some(0),
        }];
        let long = "x".repeat(33);
        let skills = [
            skill("gh-fix-ci", Some(&"d".repeat(300))),
            skill("help", Some("Would shadow help")),
            skill("model", Some("Would shadow an Inline control")),
            skill(&long, None),
            skill("has.dot", None),
            skill("bare", None),
        ];
        let menu = command_menu(base, &skills);
        let names = menu
            .iter()
            .map(|command| command["command"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(names, ["help", "gh_fix_ci", "bare"]);
        assert_eq!(
            menu[1]["description"].as_str().unwrap().chars().count(),
            256
        );
        assert_eq!(menu[2]["description"], "Run the bare skill");
    }

    #[test]
    fn menu_stops_at_the_server_limit() {
        let skills = (0..150)
            .map(|index| skill(&format!("skill{index}"), None))
            .collect::<Vec<_>>();
        assert_eq!(command_menu(Vec::new(), &skills).len(), COMMAND_LIMIT);
    }

    #[test]
    fn skills_body_matches_the_bot_api() {
        assert_eq!(
            skills_body(&[skill("a", Some("Does a")), skill("b", None)]),
            json!({ "skills": [
                { "key": "a", "name": "a", "description": "Does a", "sort_order": 0 },
                { "key": "b", "name": "b", "sort_order": 1 },
            ]})
        );
    }

    #[tokio::test]
    async fn publish_sends_skills_then_commands_with_the_bot_token() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let mut chunk = [0; 4096];
                loop {
                    let read = socket.read(&mut chunk).await.unwrap();
                    request.extend_from_slice(&chunk[..read]);
                    let text = String::from_utf8_lossy(&request).to_string();
                    let Some((head, body)) = text.split_once("\r\n\r\n") else {
                        continue;
                    };
                    let length = head
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if body.len() >= length {
                        requests.push(text);
                        break;
                    }
                }
                let reply = "{\"ok\":true,\"result\":{}}";
                socket
                    .write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                            reply.len()
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
            }
            requests
        });
        publish_to_bot(
            &format!("http://{address}/v1"),
            "bot-token",
            "claude",
            &[skill("gh-fix-ci", None)],
        )
        .await
        .unwrap();
        let requests = server.await.unwrap();
        assert!(requests[0].starts_with("POST /bot/setMySkills "));
        assert!(requests[1].starts_with("POST /bot/setMyCommands "));
        for request in &requests {
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer bot-token")
            );
        }
        assert!(requests[0].contains("\"key\":\"gh-fix-ci\""));
        assert!(requests[1].contains("\"command\":\"gh_fix_ci\""));
        assert!(requests[1].contains("\"command\":\"help\""));
    }

    #[test]
    fn bot_methods_live_beside_the_versioned_api() {
        assert_eq!(
            bot_method_url("https://api.inline.chat/v1", "setMySkills"),
            "https://api.inline.chat/bot/setMySkills"
        );
        assert_eq!(
            bot_method_url("http://localhost:8000/v1/", "setMyCommands"),
            "http://localhost:8000/bot/setMyCommands"
        );
        assert_eq!(
            bot_method_url("https://api.inline.chat", "setMySkills"),
            "https://api.inline.chat/bot/setMySkills"
        );
    }
}
