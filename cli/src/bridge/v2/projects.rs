//! The folders a thread can work in: v1's project listing (Codex's saved
//! projects and roots, and folders registered with the bridge), read from the
//! bridge store v1 keeps. v2 has no project entity of its own.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use inline_agent_bridge::{
    BridgeStore, DriverSettingsCatalog, InstallationId, WorkspaceChoice, WorkspaceId,
};
use inline_client::AgentProjectCatalog;

use super::settings::Project;

/// Where the choices are read from.
pub(crate) struct ProjectSource {
    pub store: Arc<BridgeStore>,
    pub installation_id: InstallationId,
    /// The agent's own folder, which a thread uses until it picks another.
    pub default_id: WorkspaceId,
    /// Codex's saved projects, for a Codex agent.
    pub codex_projects_path: Option<PathBuf>,
}

impl ProjectSource {
    /// The choices as the bridge lists them now: a store read and, for
    /// Codex, its saved-projects file.
    pub(crate) fn read(&self) -> Result<Projects, String> {
        let choices = crate::bridge::projects::project_choices(
            &self.store,
            &self.installation_id,
            Some(&self.default_id),
            self.codex_projects_path.as_deref(),
        )
        .map_err(|error| error.to_string())?;
        let mut folders = HashMap::new();
        for choice in &choices {
            if let Some(record) = self
                .store
                .workspace(&self.installation_id, &choice.workspace_id)
                .map_err(|error| error.to_string())?
            {
                folders.insert(choice.workspace_id.as_str().to_owned(), record.path);
            }
        }
        Ok(Projects {
            choices: choices
                .into_iter()
                .filter(|choice| folders.contains_key(choice.workspace_id.as_str()))
                .collect(),
            folders,
        })
    }
}

/// One reading of the choices.
#[derive(Clone, Debug, Default)]
pub(crate) struct Projects {
    choices: Vec<WorkspaceChoice>,
    /// Choice → its folder.
    folders: HashMap<String, PathBuf>,
}

impl Projects {
    /// The apps' project catalog, as v1 publishes it.
    pub(crate) fn catalog(&self, machine_label: &str) -> Option<AgentProjectCatalog> {
        crate::bridge::settings::agent_configuration_catalog(
            self.choices.clone(),
            &DriverSettingsCatalog::default(),
            machine_label,
        )
        .projects
    }

    /// The choices for a thread's settings.
    pub(crate) fn options(&self) -> Vec<Project> {
        self.choices
            .iter()
            .map(|choice| Project {
                id: choice.workspace_id.as_str().to_owned(),
                label: choice.display_name.clone(),
                description: choice.parent_hint.clone(),
            })
            .collect()
    }

    pub(crate) fn folder(&self, id: &str) -> Option<&Path> {
        self.folders.get(id).map(PathBuf::as_path)
    }

    /// The choice that names this folder.
    pub(crate) fn id_of(&self, folder: &Path) -> Option<&str> {
        self.folders
            .iter()
            .find(|(_, path)| path.as_path() == folder)
            .map(|(id, _)| id.as_str())
    }
}

#[cfg(test)]
impl ProjectSource {
    /// A bridge store at `store` listing `folders`, the first the agent's
    /// own. Paths are kept canonical, as the bridge keeps them.
    pub(crate) fn listing(store: &Path, installation: &str, folders: &[&Path]) -> Self {
        let store = Arc::new(BridgeStore::open(store).unwrap());
        let installation_id = InstallationId::new(installation).unwrap();
        store
            .put_installation(&inline_agent_bridge::InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: inline_agent_bridge::ProviderId::new("codex").unwrap(),
                display_name: "Agent".to_owned(),
                created_at: 1,
                updated_at: 1,
            })
            .unwrap();
        let mut ids = Vec::new();
        for folder in folders {
            let folder = std::fs::canonicalize(folder).unwrap();
            let id = crate::bridge::workspace_id(&folder).unwrap();
            store
                .discover_workspace(&installation_id, &id, &folder)
                .unwrap();
            ids.push(id);
        }
        Self {
            store,
            installation_id,
            default_id: ids.remove(0),
            codex_projects_path: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_listing_names_each_folder_and_publishes_the_agents_own_as_default() {
        let dir = tempfile::tempdir().unwrap();
        let own = dir.path().join("inline");
        let other = dir.path().join("secret-sauce");
        std::fs::create_dir(&own).unwrap();
        std::fs::create_dir(&other).unwrap();
        let source =
            ProjectSource::listing(&dir.path().join("bridge.sqlite"), "agent", &[&own, &other]);
        let projects = source.read().unwrap();
        let other = std::fs::canonicalize(other).unwrap();
        let other_id = projects.id_of(&other).expect("listed").to_owned();
        assert_eq!(projects.folder(&other_id), Some(other.as_path()));
        let options = projects.options();
        assert!(
            options
                .iter()
                .any(|option| option.id == other_id && option.label == "secret-sauce")
        );
        // v1's listing always offers the home folder as "No project".
        assert!(options.iter().any(|option| option.label == "No project"));
        let catalog = projects.catalog("MacBook").unwrap();
        assert_eq!(
            catalog.default_project_id.as_deref(),
            Some(source.default_id.as_str())
        );
        assert_eq!(
            catalog.options[0].description.as_deref(),
            Some("Local project · MacBook")
        );
        assert!(projects.folder("workspace-unknown").is_none());
    }
}
