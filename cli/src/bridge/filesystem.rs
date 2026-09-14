//! Owner-only metadata browser. Never reads file contents or runs shell commands.
use super::*;
use inline_sdk::proto::bot_filesystem_entry::Kind;
use inline_sdk::proto::bot_filesystem_response::Result as Reply;
use inline_sdk::proto::{BotFilesystemEntry, BotFilesystemListing, BotFilesystemResponse};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const PAGE_SIZE: usize = 200;
const MAX_SCAN: usize = 100_000;
static BROWSE_SLOTS: std::sync::LazyLock<std::sync::Arc<tokio::sync::Semaphore>> =
    std::sync::LazyLock::new(|| std::sync::Arc::new(tokio::sync::Semaphore::new(2)));

fn problem(message: &str) -> BotFilesystemResponse {
    BotFilesystemResponse {
        result: Some(Reply::Problem(message.to_owned())),
    }
}

fn safe_path(path: &Path) -> bool {
    // No contents are read, and sensitive environment files are not inspected.
    !path.components().any(|part| {
        part.as_os_str()
            .to_str()
            .is_some_and(|s| s == ".env" || s.starts_with(".env."))
    })
}

fn resolve_directory(path: &str) -> Result<PathBuf, &'static str> {
    if path.len() > 4096 || path.chars().any(char::is_control) {
        return Err("That path is not supported.");
    }
    let path = if path.is_empty() {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or("The host home directory is unavailable.")?
    } else {
        PathBuf::from(path)
    };
    if !path.is_absolute() || !safe_path(&path) {
        return Err("That path is not supported.");
    }
    let canonical =
        std::fs::canonicalize(path).map_err(|_| "That folder is missing or not accessible.")?;
    if !safe_path(&canonical) || !canonical.is_dir() {
        return Err("Choose an accessible folder.");
    }
    if canonical.to_str().is_none() {
        return Err("This folder name is not supported.");
    }
    Ok(canonical)
}

fn list_directory(path: &str, after: &str) -> Result<BotFilesystemListing, &'static str> {
    if after.len() > 1024
        || after.contains('/')
        || after.contains('\\')
        || after.chars().any(char::is_control)
    {
        return Err("That directory page is not available.");
    }
    let canonical = resolve_directory(path)?;
    let mut candidates = BTreeMap::new();
    for (index, item) in std::fs::read_dir(&canonical)
        .map_err(|_| "This folder cannot be opened.")?
        .enumerate()
    {
        if index >= MAX_SCAN {
            return Err("This folder is too large to browse in this version.");
        }
        let item =
            item.map_err(|_| "The directory changed or cannot be read. Refresh to try again.")?;
        let Ok(name) = item.file_name().into_string() else {
            continue;
        };
        if name.len() > 1024
            || name.chars().any(char::is_control)
            || name.contains('\\')
            || !safe_path(Path::new(&name))
            || name.as_str() <= after
        {
            continue;
        }
        candidates.insert(name, item);
        if candidates.len() > PAGE_SIZE + 1 {
            candidates.pop_last();
        }
    }
    let more = candidates.len() > PAGE_SIZE;
    if more {
        candidates.pop_last();
    }
    let mut entries = Vec::with_capacity(candidates.len());
    for (name, item) in candidates {
        // symlink_metadata does not inspect the destination of a file link.
        let metadata = std::fs::symlink_metadata(item.path())
            .map_err(|_| "The directory changed or cannot be read. Refresh to try again.")?;
        let kind = if metadata.is_dir() {
            Kind::Directory
        } else if metadata.is_file() {
            Kind::File
        } else if metadata.file_type().is_symlink() {
            Kind::Symlink
        } else {
            Kind::Other
        };
        entries.push(BotFilesystemEntry {
            name,
            kind: kind as i32,
            size: if metadata.is_file() {
                metadata.len()
            } else {
                0
            },
        });
    }
    let next_after = if more {
        entries.last().map(|e| e.name.clone())
    } else {
        None
    };
    Ok(BotFilesystemListing {
        path: canonical.to_str().unwrap().to_owned(),
        parent_path: canonical.parent().and_then(Path::to_str).map(str::to_owned),
        entries,
        next_after,
    })
}

pub(super) async fn handle_filesystem_event<D: AgentDriver + 'static>(
    bot: &InlineClient,
    event: &ClientEvent,
    runtime: &SettingsRuntime<'_, D>,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::BotInteraction(BotInteractionEvent::FilesystemRequested {
        request_id,
        chat_id,
        actor_user_id,
        bot_user_id,
        host_installation_id,
        operation,
        path,
        after,
    }) = event
    else {
        return Ok(false);
    };
    // Other hosts sharing this bot must not win the response race.
    if host_installation_id != &runtime.identity.host_installation_id {
        return Ok(true);
    }
    let snapshot = runtime.active.snapshot();
    let response = if actor_user_id.get() != runtime.identity.owner_user_id
        || bot_user_id.get() != runtime.identity.bot_user_id
    {
        problem("Only the bot owner can browse this machine.")
    } else if host_installation_id != &runtime.identity.host_installation_id
        || chat_id.get() != snapshot.binding.chat_id
    {
        problem("This request belongs to a different host or conversation. Reopen Agent Settings.")
    } else {
        let path = path.clone();
        let after = after.clone();
        match *operation {
            1 => {
                let Ok(permit) = BROWSE_SLOTS.clone().try_acquire_owned() else {
                    let _ = bot
                        .answer_bot_filesystem(proto::AnswerBotFilesystemInput {
                            request_id: *request_id,
                            response: Some(problem("The remote browser is busy. Try again.")),
                        })
                        .await;
                    return Ok(true);
                };
                match tokio::time::timeout(
                    Duration::from_secs(3),
                    tokio::task::spawn_blocking(move || {
                        let _permit = permit;
                        list_directory(&path, &after)
                    }),
                )
                .await
                {
                    Ok(Ok(Ok(listing))) => BotFilesystemResponse {
                        result: Some(Reply::Listing(listing)),
                    },
                    Ok(Ok(Err(message))) => problem(message),
                    _ => problem(
                        "The remote browser could not finish the request. Try another folder.",
                    ),
                }
            }
            2 if after.is_empty() && !path.is_empty() => {
                let Ok(permit) = BROWSE_SLOTS.clone().try_acquire_owned() else {
                    let _ = bot
                        .answer_bot_filesystem(proto::AnswerBotFilesystemInput {
                            request_id: *request_id,
                            response: Some(problem("The remote browser is busy. Try again.")),
                        })
                        .await;
                    return Ok(true);
                };
                match tokio::time::timeout(
                    Duration::from_secs(3),
                    tokio::task::spawn_blocking(move || {
                        let _permit = permit;
                        resolve_directory(&path)
                    }),
                )
                .await
                {
                    Ok(Ok(Ok(canonical))) => {
                        match validate_workspace_choice(canonical).and_then(|path| {
                            let id = workspace_id(&path)?;
                            Ok(runtime.store.select_workspace(
                                &snapshot.binding.installation_id,
                                &id,
                                &path,
                                now_seconds(),
                            )?)
                        }) {
                            Ok(workspace) => BotFilesystemResponse {
                                result: Some(Reply::WorkspaceId(
                                    workspace.workspace_id.to_string(),
                                )),
                            },
                            Err(_) => problem("This folder cannot be used as a project."),
                        }
                    }
                    _ => problem("Choose an accessible folder."),
                }
            }
            _ => problem("This remote browser operation is not supported."),
        }
    };
    // A late/expired answer must never tear down the agent provider.
    let _ = bot
        .answer_bot_filesystem(proto::AnswerBotFilesystemInput {
            request_id: *request_id,
            response: Some(response),
        })
        .await;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_relative_and_sensitive_paths_without_access() {
        assert!(resolve_directory("relative").is_err());
        assert!(resolve_directory("/tmp/.env").is_err());
        assert!(resolve_directory("/tmp/.env.local").is_err());
        assert!(list_directory("", "../").is_err());
    }
    #[test]
    fn lists_bounded_pages_and_metadata() {
        let dir = tempfile::tempdir().unwrap();
        for i in 0..205 {
            std::fs::write(dir.path().join(format!("file-{i:03}")), b"hello").unwrap();
        }
        std::fs::create_dir(dir.path().join("folder")).unwrap();
        let path = dir.path().to_str().unwrap();
        let first = list_directory(path, "").unwrap();
        assert_eq!(first.entries.len(), 200);
        assert_eq!(first.entries[0].size, 5);
        let second = list_directory(path, first.next_after.as_deref().unwrap()).unwrap();
        assert_eq!(second.entries.len(), 6);
        assert!(second.next_after.is_none());
        assert_eq!(second.entries.last().unwrap().kind, Kind::Directory as i32);
    }
    #[cfg(unix)]
    #[test]
    fn directory_links_resolve_but_file_links_only_expose_link_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("note"), b"metadata only").unwrap();
        std::os::unix::fs::symlink(&target, dir.path().join("folder-link")).unwrap();
        std::os::unix::fs::symlink(target.join("note"), dir.path().join("file-link")).unwrap();
        let listing = list_directory(dir.path().to_str().unwrap(), "").unwrap();
        let link = listing
            .entries
            .iter()
            .find(|e| e.name == "file-link")
            .unwrap();
        assert_eq!(link.kind, Kind::Symlink as i32);
        assert_eq!(link.size, 0);
        let opened = list_directory(dir.path().join("folder-link").to_str().unwrap(), "").unwrap();
        assert_eq!(
            opened.path,
            std::fs::canonicalize(target).unwrap().to_str().unwrap()
        );
        assert_eq!(opened.entries.len(), 1);
        assert!(list_directory(dir.path().join("file-link").to_str().unwrap(), "").is_err());
    }
}
