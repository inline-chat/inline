//! Read saved local Codex projects on demand; never infer projects from recent
//! sessions or write Codex's state. Discovered paths use the existing registry.

use std::io::Read;

use super::*;
use inline_agent_driver_codex::{CodexAppServerDriver, CodexDriverWriter, CodexRpc, PeerError};

const MAX_CODEX_STATE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_SAVED_PROJECTS: usize = 1_000;

pub(super) fn codex_driver(
    driver: &ProviderDriver,
) -> Option<CodexAppServerDriver<CodexDriverWriter>> {
    match driver {
        ProviderDriver::Codex(driver) => Some(driver.clone()),
        ProviderDriver::Acp(_) => None,
    }
}

#[derive(Deserialize)]
struct ProjectPage {
    data: Vec<ProviderProject>,
    #[serde(default, rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Deserialize)]
struct ProviderProject {
    roots: Vec<ProjectRoot>,
}

#[derive(Deserialize)]
struct ProjectRoot {
    path: PathBuf,
}

async fn provider_roots(rpc: &impl CodexRpc) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let mut cursor = None;
    let mut cursors = HashSet::new();
    let mut roots = Vec::new();
    for _ in 0..10 {
        let response = match rpc
            .request(
                "project/list",
                serde_json::json!({"cursor": cursor, "limit": 100}),
            )
            .await
        {
            Ok(response) => response,
            Err(PeerError::Remote(error))
                if error.code == Some(-32601)
                    || (error.code == Some(-32600)
                        && error.message.contains("unknown variant `project/list`")) =>
            {
                return Ok(Vec::new());
            }
            Err(error) => return Err(error.into()),
        };
        let page: ProjectPage = serde_json::from_value(response)
            .map_err(|_| io::Error::other("Codex returned invalid project metadata"))?;
        roots.extend(
            page.data
                .into_iter()
                .flat_map(|project| project.roots.into_iter().map(|root| root.path)),
        );
        if roots.len() > MAX_SAVED_PROJECTS {
            return Err(io::Error::other("Codex has more than 1000 project roots").into());
        }
        let Some(next) = page.next_cursor else {
            return Ok(roots);
        };
        if next.is_empty() || !cursors.insert(next.clone()) {
            return Err(io::Error::other("Codex project pagination did not advance").into());
        }
        cursor = Some(next);
    }
    Err(io::Error::other("Codex project pagination exceeded its read budget").into())
}

pub(super) async fn refresh_provider_projects<D: AgentDriver + 'static>(
    runtime: &SettingsRuntime<'_, D>,
    snapshot: &ConversationSnapshot,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(rpc) = runtime
        .identity
        .codex_project_rpc
        .as_ref()
        .filter(|_| !runtime.turn_active)
    else {
        return Ok(());
    };
    let Some(_lease) = runtime.sessions.try_begin_provider_work()? else {
        return Err(io::Error::other("the agent connection is being released").into());
    };
    let roots = tokio::time::timeout(Duration::from_secs(4), provider_roots(rpc))
        .await
        .map_err(|_| io::Error::other("Codex project discovery timed out"))??;
    for path in roots {
        if !path.is_absolute() {
            continue;
        }
        let Some(canonical) = canonical_workspace(&path)
            .ok()
            .and_then(|path| validate_workspace_choice(path).ok())
        else {
            continue;
        };
        runtime.store.discover_workspace(
            &snapshot.binding.installation_id,
            &workspace_id(&canonical)?,
            &canonical,
        )?;
    }
    Ok(())
}

#[derive(Deserialize)]
struct SavedProjects {
    #[serde(default, rename = "electron-saved-workspace-roots")]
    roots: Vec<serde_json::Value>,
    #[serde(default, rename = "local-projects")]
    projects: std::collections::BTreeMap<String, SavedProject>,
}

#[derive(Deserialize)]
struct SavedProject {
    #[serde(default, rename = "rootPaths")]
    roots: Vec<String>,
}

pub(super) fn codex_projects_path(provider_id: &str) -> Option<PathBuf> {
    if provider_id != "codex" {
        return None;
    }
    let home = env::var_os("CODEX_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))?;
    home.is_absolute()
        .then(|| home.join(".codex-global-state.json"))
}

pub(super) fn project_choices(
    store: &BridgeStore,
    installation_id: &InstallationId,
    selected: Option<&WorkspaceId>,
    codex_state_path: Option<&Path>,
) -> Result<Vec<WorkspaceChoice>, Box<dyn std::error::Error>> {
    if let Some(path) = codex_state_path {
        discover_saved_projects(store, installation_id, path)?;
    }
    store.refresh_workspace_availability(installation_id, now_seconds())?;
    Ok(store.project_workspace_choices(installation_id, selected)?)
}

fn discover_saved_projects(
    store: &BridgeStore,
    installation_id: &InstallationId,
    state_path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let file = match fs::File::open(state_path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let mut bytes = Vec::new();
    file.take(MAX_CODEX_STATE_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_CODEX_STATE_BYTES {
        return Err(io::Error::other("Codex project state exceeds the supported size").into());
    }
    let saved: SavedProjects = serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::other("Codex saved projects could not be read"))?;
    let roots = saved
        .projects
        .values()
        .flat_map(|project| project.roots.iter().map(String::as_str))
        .chain(saved.roots.iter().filter_map(serde_json::Value::as_str))
        .collect::<std::collections::BTreeSet<_>>();
    if roots.len() > MAX_SAVED_PROJECTS {
        return Err(io::Error::other("Codex has more than 1000 saved projects").into());
    }
    let mut seen = HashSet::new();
    for root in roots {
        let path = Path::new(root);
        if !path.is_absolute() {
            continue;
        }
        let Some(canonical) = canonical_workspace(path)
            .ok()
            .and_then(|path| validate_workspace_choice(path).ok())
        else {
            continue;
        };
        if seen.insert(canonical.clone()) {
            store.discover_workspace(installation_id, &workspace_id(&canonical)?, &canonical)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_driver_codex::{CodexRpcFuture, RemoteError};
    use std::collections::VecDeque;
    use std::sync::Mutex;

    struct ProjectRpc {
        responses: Mutex<VecDeque<Result<serde_json::Value, PeerError>>>,
        requests: Mutex<Vec<serde_json::Value>>,
    }

    impl ProjectRpc {
        fn new(responses: Vec<Result<serde_json::Value, PeerError>>) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl CodexRpc for ProjectRpc {
        fn request<'a>(
            &'a self,
            method: &'static str,
            params: serde_json::Value,
        ) -> CodexRpcFuture<'a> {
            assert_eq!(method, "project/list");
            self.requests.lock().unwrap().push(params);
            let result = self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected request");
            Box::pin(async move { result })
        }
    }

    #[tokio::test]
    async fn provider_projects_follow_cursors_and_include_every_root() {
        let rpc = ProjectRpc::new(vec![
            Ok(
                serde_json::json!({"data": [{"roots": [{"path": "/one"}, {"path": "/two"}]}], "nextCursor": "second"}),
            ),
            Ok(serde_json::json!({"data": [{"roots": [{"path": "/three"}]}], "nextCursor": null})),
        ]);
        assert_eq!(
            provider_roots(&rpc).await.unwrap(),
            vec![
                PathBuf::from("/one"),
                PathBuf::from("/two"),
                PathBuf::from("/three")
            ]
        );
        assert_eq!(
            *rpc.requests.lock().unwrap(),
            vec![
                serde_json::json!({"limit": 100, "cursor": null}),
                serde_json::json!({"limit": 100, "cursor": "second"}),
            ]
        );
    }

    #[tokio::test]
    async fn older_codex_without_projects_uses_saved_folder_fallback() {
        for (code, message) in [
            (-32601, "Method not found"),
            (
                -32600,
                "unknown variant `project/list`, expected `initialize`",
            ),
        ] {
            let rpc = ProjectRpc::new(vec![Err(PeerError::Remote(RemoteError {
                code: Some(code),
                message: message.to_string(),
            }))]);
            assert!(provider_roots(&rpc).await.unwrap().is_empty());
        }
        let rpc = ProjectRpc::new(vec![Err(PeerError::Remote(RemoteError {
            code: Some(-32600),
            message: "bad cursor".to_string(),
        }))]);
        assert!(
            provider_roots(&rpc).await.is_err(),
            "a supported RPC failure must not become an empty list"
        );
    }

    #[tokio::test]
    async fn malformed_and_nonadvancing_project_pages_are_not_partial_success() {
        for responses in [
            vec![serde_json::json!({"data": [{"roots": "invalid"}]})],
            vec![
                serde_json::json!({"data": [], "nextCursor": "again"}),
                serde_json::json!({"data": [], "nextCursor": "again"}),
            ],
            vec![serde_json::json!({"data": [], "nextCursor": ""})],
            (0..10)
                .map(|i| serde_json::json!({"data": [], "nextCursor": i.to_string()}))
                .collect(),
        ] {
            assert!(
                provider_roots(&ProjectRpc::new(responses.into_iter().map(Ok).collect()))
                    .await
                    .is_err()
            );
        }
    }

    #[test]
    fn saved_projects_include_modern_and_legacy_roots_beyond_recent_limit() {
        let directory = tempfile::tempdir().unwrap();
        let store = BridgeStore::open_in_memory().unwrap();
        let installation = InstallationId::new("project-test").unwrap();
        store
            .put_installation(&InstallationRecord {
                installation_id: installation.clone(),
                provider_id: ProviderId::new("codex").unwrap(),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .unwrap();
        let selected = directory.path().join("selected");
        fs::create_dir(&selected).unwrap();
        let selected = fs::canonicalize(selected).unwrap();
        let selected_id = workspace_id(&selected).unwrap();
        store
            .select_workspace(&installation, &selected_id, &selected, 50)
            .unwrap();
        let before = store
            .workspace(&installation, &selected_id)
            .unwrap()
            .unwrap();
        let mut roots = Vec::new();
        for index in 0..12 {
            let path = directory.path().join(format!("project-{index:02}"));
            fs::create_dir(&path).unwrap();
            roots.push(path);
        }
        let state_path = directory.path().join("codex-state.json");
        let state = serde_json::to_vec(&serde_json::json!({
            "electron-saved-workspace-roots": [roots[0], selected, "/", "relative", null],
            "local-projects": {"saved": {"rootPaths": roots, "name": "Saved project"}},
            "active-workspace-roots": ["/this-is-not-a-project-catalog"],
            "ignored-field": "must not influence discovery"
        }))
        .unwrap();
        fs::write(&state_path, &state).unwrap();
        for _ in 0..2 {
            let choices =
                project_choices(&store, &installation, Some(&selected_id), Some(&state_path))
                    .unwrap();
            assert_eq!(choices.len(), 13);
            assert!(choices.iter().any(|choice| choice.selected));
            assert_eq!(
                store
                    .default_workspace(&installation)
                    .unwrap()
                    .unwrap()
                    .workspace_id,
                selected_id
            );
            assert_eq!(
                store
                    .workspace(&installation, &selected_id)
                    .unwrap()
                    .unwrap(),
                before
            );
        }
        assert_eq!(
            fs::read(state_path).unwrap(),
            state,
            "Codex state is read-only"
        );
        assert_eq!(
            store
                .recent_workspace_choices(&installation, Some(&selected_id))
                .unwrap()
                .len(),
            8
        );
    }

    #[test]
    fn malformed_codex_project_state_fails_without_touching_existing_selection() {
        let directory = tempfile::tempdir().unwrap();
        let store = BridgeStore::open_in_memory().unwrap();
        let installation = InstallationId::new("project-test").unwrap();
        let state_path = directory.path().join("codex-state.json");
        assert!(discover_saved_projects(&store, &installation, &state_path).is_ok());
        fs::write(&state_path, b"{").unwrap();
        let error = discover_saved_projects(&store, &installation, &state_path).unwrap_err();
        assert_eq!(error.to_string(), "Codex saved projects could not be read");
    }
}
