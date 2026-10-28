//! The folders a thread can pick: the agent's own, the ones its harness
//! knows (Codex's projects) and the ones registered with the bridge. Each is
//! offered once, by canonical path, under an opaque id the apps keep.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use inline_agent_bridge::harness::CatalogFolder;
use inline_agent_bridge::{BridgeStore, InstallationId};
use inline_client::{AgentProjectCatalog, AgentProjectOption};

use super::settings::Folder;

/// Where folders registered with the bridge are read from.
pub(crate) struct FolderSource {
    pub store: Arc<BridgeStore>,
    pub installation_id: InstallationId,
}

impl FolderSource {
    /// The folders a thread can pick now: the agent's own first, then the
    /// harness's in its order, then the registered ones. A folder keeps the
    /// first name it is given, so a Codex project shows under its own name.
    pub(crate) fn read(&self, own: &Path, harness: &[CatalogFolder]) -> Result<Folders, String> {
        let mut named: Vec<(PathBuf, Option<String>)> = vec![(own.to_path_buf(), None)];
        named.extend(
            harness
                .iter()
                .map(|folder| (folder.path.clone(), Some(folder.label.clone()))),
        );
        let registered = self
            .store
            .project_workspace_choices(&self.installation_id, None)
            .map_err(|error| error.to_string())?;
        for choice in registered {
            if let Some(record) = self
                .store
                .workspace(&self.installation_id, &choice.workspace_id)
                .map_err(|error| error.to_string())?
            {
                named.push((record.path, Some(record.display_name)));
            }
        }
        Ok(Folders::merge(own, named))
    }
}

struct Entry {
    id: String,
    label: String,
    path: PathBuf,
}

/// One reading of the folders.
#[derive(Default)]
pub(crate) struct Folders {
    entries: Vec<Entry>,
    /// The agent's own folder, when it exists.
    default_id: Option<String>,
}

impl Folders {
    fn merge(own: &Path, named: Vec<(PathBuf, Option<String>)>) -> Self {
        let mut entries: Vec<Entry> = Vec::new();
        let mut unnamed: Vec<bool> = Vec::new();
        for (path, label) in named {
            let Some(path) = std::fs::canonicalize(&path)
                .ok()
                .filter(|path| path.is_dir() && path.parent().is_some())
            else {
                continue;
            };
            match entries.iter().position(|entry| entry.path == path) {
                Some(index) => {
                    if unnamed[index]
                        && let Some(label) = label
                    {
                        entries[index].label = label;
                        unnamed[index] = false;
                    }
                }
                None => {
                    let Some(id) = folder_id(&path) else {
                        continue;
                    };
                    unnamed.push(label.is_none());
                    entries.push(Entry {
                        id,
                        label: label.unwrap_or_else(|| folder_name(&path)),
                        path,
                    });
                }
            }
        }
        let default_id = std::fs::canonicalize(own)
            .ok()
            .and_then(|own| entries.iter().find(|entry| entry.path == own))
            .map(|entry| entry.id.clone());
        Self {
            entries,
            default_id,
        }
    }

    /// The apps' project catalog: the folders Inline takes (at most 500),
    /// the agent's own among them and the default.
    pub(crate) fn catalog(&self, machine_label: &str) -> Option<AgentProjectCatalog> {
        const MAX_CATALOG_FOLDERS: usize = 500;
        let mut entries: Vec<&Entry> = self.entries.iter().take(MAX_CATALOG_FOLDERS).collect();
        if let Some(default) = self.default_id.as_deref()
            && !entries.iter().any(|entry| entry.id == default)
            && let Some(own) = self.entries.iter().find(|entry| entry.id == default)
        {
            entries.pop();
            entries.push(own);
        }
        (!entries.is_empty()).then(|| AgentProjectCatalog {
            options: entries
                .into_iter()
                .map(|entry| AgentProjectOption {
                    id: entry.id.clone(),
                    label: entry.label.clone(),
                    description: Some(format!("On {machine_label}")),
                })
                .collect(),
            can_select_folder: None,
            default_project_id: self.default_id.clone(),
        })
    }

    /// The choices for a thread's settings; two folders of the same name say
    /// where they are.
    pub(crate) fn options(&self) -> Vec<Folder> {
        let mut names: HashMap<&str, usize> = HashMap::new();
        for entry in &self.entries {
            *names.entry(entry.label.as_str()).or_default() += 1;
        }
        self.entries
            .iter()
            .map(|entry| Folder {
                id: entry.id.clone(),
                label: entry.label.clone(),
                description: (names[entry.label.as_str()] > 1)
                    .then(|| entry.path.parent().map(home_relative))
                    .flatten(),
            })
            .collect()
    }

    pub(crate) fn folder(&self, id: &str) -> Option<&Path> {
        self.entries
            .iter()
            .find(|entry| entry.id == id)
            .map(|entry| entry.path.as_path())
    }

    /// The id of a folder, as the thread keeps it.
    pub(crate) fn id_of(&self, folder: &Path) -> Option<&str> {
        let folder = std::fs::canonicalize(folder).ok()?;
        self.entries
            .iter()
            .find(|entry| entry.path == folder)
            .map(|entry| entry.id.as_str())
    }
}

/// The same opaque id v1 gives a folder.
fn folder_id(path: &Path) -> Option<String> {
    crate::bridge::workspace_id(path)
        .ok()
        .map(|id| id.as_str().to_owned())
}

fn folder_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// `~/dev` rather than `/Users/mo/dev`.
fn home_relative(path: &Path) -> String {
    std::env::var_os("HOME")
        .and_then(|home| std::fs::canonicalize(home).ok())
        .and_then(|home| path.strip_prefix(home).ok().map(Path::to_path_buf))
        .map_or_else(
            || path.display().to_string(),
            |relative| format!("~/{}", relative.display()),
        )
}

#[cfg(test)]
impl FolderSource {
    /// A bridge store at `store` with `registered` folders.
    pub(crate) fn listing(store: &Path, installation: &str, registered: &[&Path]) -> Self {
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
        for folder in registered {
            let folder = std::fs::canonicalize(folder).unwrap();
            store
                .discover_workspace(
                    &installation_id,
                    &crate::bridge::workspace_id(&folder).unwrap(),
                    &folder,
                )
                .unwrap();
        }
        Self {
            store,
            installation_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_merge_by_path_and_keep_the_harness_name() {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let [own, codex, registered, gone, twin] =
            ["inline", "site", "notes", "gone", "other/inline"].map(|name| root.join(name));
        for folder in [&own, &codex, &registered, &twin] {
            std::fs::create_dir_all(folder).unwrap();
        }
        let source = FolderSource::listing(
            &root.join("bridge.sqlite"),
            "agent",
            &[&registered, &codex, &twin],
        );
        let harness = [
            CatalogFolder {
                path: own.clone(),
                label: "inline".to_owned(),
            },
            CatalogFolder {
                // The same folder by another path.
                path: root.join("site/../site"),
                label: "Website".to_owned(),
            },
            CatalogFolder {
                path: gone.clone(),
                label: "Gone".to_owned(),
            },
        ];
        let folders = source.read(&own, &harness).unwrap();
        let options = folders.options();
        let labels: Vec<&str> = options.iter().map(|option| option.label.as_str()).collect();
        // Registered folders follow, by name; the harness's own name wins.
        assert_eq!(labels, ["inline", "Website", "inline", "notes"]);
        assert!(options[0].description.is_some() && options[2].description.is_some());
        assert_ne!(
            options[0].description, options[2].description,
            "two folders named inline say where"
        );
        assert!(options[1].description.is_none());

        let own_id = folders.id_of(&own).unwrap().to_owned();
        assert_eq!(
            own_id,
            crate::bridge::workspace_id(&own).unwrap().as_str(),
            "ids are v1's"
        );
        assert_eq!(folders.folder(&own_id), Some(own.as_path()));
        assert!(folders.folder("workspace-unknown").is_none());

        let catalog = folders.catalog("MacBook").unwrap();
        assert_eq!(catalog.default_project_id.as_deref(), Some(own_id.as_str()));
        assert_eq!(catalog.options.len(), 4);
        assert!(
            catalog
                .options
                .iter()
                .all(|option| option.description.as_deref() == Some("On MacBook"))
        );
    }

    #[test]
    fn the_agents_own_folder_is_offered_without_any_listing() {
        let dir = tempfile::tempdir().unwrap();
        let own = std::fs::canonicalize(dir.path()).unwrap().join("work");
        std::fs::create_dir(&own).unwrap();
        let source = FolderSource::listing(&dir.path().join("bridge.sqlite"), "agent", &[]);
        let folders = source.read(&own, &[]).unwrap();
        let options = folders.options();
        assert_eq!(options.len(), 1);
        assert_eq!(options[0].label, "work");
    }
}
