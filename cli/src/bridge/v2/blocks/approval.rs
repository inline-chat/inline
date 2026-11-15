//! Command, file-change, tool, permission and network approvals: Claude's
//! permission card, Codex's exec and patch approvals.
//!
//! One `approval` block: the subject, a title, the command in a monospaced
//! box, the folder and the model's reason, and what is approved (diffs, or
//! the tool's input) as children. The buttons are the interaction's
//! advertised decisions with the harness's own labels. Everyone in the thread
//! sees the full details (Oct 24: no premature filtering).

use std::path::Path;

use inline_agent_bridge::harness::{ApprovalSubject, FileChangeKind, FileDiff};
use inline_protocol::proto;
use serde_json::Value;

use super::{Resolution, head, plan_proposal};
use crate::bridge::v2::doc::{DiffChange, Doc, DocBuilder};

/// A command or tool input the card shows before cutting it.
const MAX_DETAIL_CHARS: usize = 2_000;
/// Diff text one card shows in all; later files list by name.
const MAX_DIFF_CHARS: usize = 8_000;

use proto::block_approval::Subject;

/// The card for `subject`. `diffs` are the changes of the item it is about,
/// when the harness reported them (Codex file changes).
pub(crate) fn card(
    agent: &str,
    subject: &ApprovalSubject,
    diffs: &[FileDiff],
    folder: Option<&Path>,
    action_ids: &[String],
    resolution: &Resolution,
) -> Doc {
    if let ApprovalSubject::Plan { plan } = subject {
        return plan_proposal::card(agent, plan, action_ids, resolution);
    }
    let mut builder = DocBuilder::new();
    let mut approval = proto::BlockApproval {
        state: resolution.state as i32,
        action_ids: resolution.action_ids(action_ids),
        decided_by_user_id: resolution.by,
        ..Default::default()
    };
    match subject {
        ApprovalSubject::Command {
            command,
            cwd,
            reason,
            network_host,
            permissions,
        } => {
            let title = match network_host {
                Some(host) => format!("{agent} wants network access to {host}"),
                None => format!("{agent} wants to run a command"),
            };
            approval.subject = if network_host.is_some() {
                Subject::Network
            } else {
                Subject::Command
            } as i32;
            approval.title = Some(builder.span(&title));
            approval.command = labelled(&mut builder, "Command", &head(command, MAX_DETAIL_CHARS));
            approval.cwd = labelled(
                &mut builder,
                "Folder",
                &cwd.as_ref()
                    .map(|cwd| cwd.display().to_string())
                    .unwrap_or_default(),
            );
            approval.reason = labelled(&mut builder, "Reason", reason.as_deref().unwrap_or(""));
            approval.children = builder.nested(|inner| {
                inner.fields(&[
                    ("Host", network_host.clone().unwrap_or_default(), true),
                    (
                        "Permissions",
                        permissions.clone().unwrap_or_default(),
                        false,
                    ),
                ]);
            });
        }
        ApprovalSubject::FileChange {
            paths,
            reason,
            grant_root,
        } => {
            approval.subject = Subject::FileChange as i32;
            approval.title = Some(builder.span(&format!("{agent} wants to edit files")));
            approval.reason = labelled(&mut builder, "Reason", reason.as_deref().unwrap_or(""));
            let shown: Vec<&FileDiff> = diffs
                .iter()
                .filter(|diff| paths.is_empty() || paths.contains(&diff.path))
                .collect();
            approval.children = builder.nested(|inner| {
                let listed: Vec<&std::path::PathBuf> = paths
                    .iter()
                    .filter(|path| !shown.iter().any(|diff| &diff.path == *path))
                    .collect();
                write_diffs(inner, &shown, folder);
                inner.fields(&[
                    ("Files", path_list(&listed), true),
                    (
                        "Write access to",
                        grant_root
                            .as_ref()
                            .map(|root| root.display().to_string())
                            .unwrap_or_default(),
                        true,
                    ),
                ]);
            });
        }
        ApprovalSubject::Permissions { summary, reason } => {
            approval.subject = Subject::Permissions as i32;
            approval.title = Some(builder.span(&format!("{agent} asks for more permissions")));
            approval.reason = labelled(&mut builder, "Reason", reason.as_deref().unwrap_or(""));
            approval.children = builder.nested(|inner| {
                inner.fields(&[("Permissions", summary.clone(), false)]);
            });
        }
        ApprovalSubject::Tool {
            name,
            input,
            reason,
        } => match edit_of(name, input) {
            Some((verb, diff)) => {
                approval.subject = Subject::FileChange as i32;
                let path = relative(&diff.path, folder);
                approval.title = Some(builder.span(&format!("{agent} wants to {verb} {path}")));
                approval.reason = labelled(&mut builder, "Reason", reason.as_deref().unwrap_or(""));
                approval.children = builder.nested(|inner| write_diffs(inner, &[&diff], folder));
            }
            None => {
                approval.subject = Subject::Tool as i32;
                approval.title = Some(builder.span(&format!("{agent} wants to use {name}")));
                approval.reason = labelled(&mut builder, "Reason", reason.as_deref().unwrap_or(""));
                approval.children = builder.nested(|inner| {
                    if !input.is_null() {
                        inner.code(
                            &head(
                                &serde_json::to_string_pretty(input).unwrap_or_default(),
                                MAX_DETAIL_CHARS,
                            ),
                            Some("json"),
                        );
                    }
                });
            }
        },
        ApprovalSubject::Other { title, detail } => {
            approval.title = Some(builder.span(&format!("{agent}: {title}")));
            approval.children = builder.nested(|inner| {
                if let Some(detail) = detail {
                    inner.paragraph(detail);
                }
            });
        }
        ApprovalSubject::Plan { .. } => unreachable!("plans are plan proposals"),
    }
    builder.push_block(proto::block::Kind::Approval(approval));
    resolution.write_note(&mut builder);
    builder.finish()
}

/// "Label: value" on its own line; the range covers the value.
fn labelled(builder: &mut DocBuilder, label: &str, value: &str) -> Option<proto::BlockText> {
    if value.trim().is_empty() {
        return None;
    }
    builder.push_raw(&format!("{label}: "));
    let span = builder.inline_span(value.trim_end());
    builder.newline();
    Some(span)
}

fn write_diffs(builder: &mut DocBuilder, diffs: &[&FileDiff], folder: Option<&Path>) {
    let mut shown = 0;
    for change in diffs {
        let kind = match &change.change {
            FileChangeKind::Add => DiffChange::Added,
            FileChangeKind::Delete => DiffChange::Deleted,
            FileChangeKind::Update { moved_to: Some(_) } => DiffChange::Renamed,
            FileChangeKind::Update { moved_to: None } => DiffChange::Modified,
        };
        let diff = change
            .diff
            .as_deref()
            .filter(|_| shown < MAX_DIFF_CHARS)
            .map(|diff| head(diff, MAX_DIFF_CHARS));
        shown += diff.as_deref().map_or(0, str::len);
        builder.diff(&relative(&change.path, folder), kind, diff.as_deref());
    }
}

/// Claude's file tools as the change they make, with a diff built from
/// their input.
fn edit_of(name: &str, input: &Value) -> Option<(&'static str, FileDiff)> {
    let path = input["file_path"]
        .as_str()
        .or_else(|| input["notebook_path"].as_str())?;
    let lines = |prefix: char, text: &str| -> Vec<String> {
        text.lines().map(|line| format!("{prefix}{line}")).collect()
    };
    let replace = |edit: &Value| -> Vec<String> {
        let mut out = vec!["@@".to_owned()];
        out.extend(lines('-', edit["old_string"].as_str().unwrap_or("")));
        out.extend(lines('+', edit["new_string"].as_str().unwrap_or("")));
        out
    };
    let (verb, change, diff) = match name {
        "Write" => (
            "write",
            FileChangeKind::Add,
            lines('+', input["content"].as_str().unwrap_or("")),
        ),
        "Edit" => (
            "edit",
            FileChangeKind::Update { moved_to: None },
            replace(input),
        ),
        "MultiEdit" => (
            "edit",
            FileChangeKind::Update { moved_to: None },
            input["edits"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(replace)
                .collect(),
        ),
        _ => return None,
    };
    Some((
        verb,
        FileDiff {
            path: path.into(),
            change,
            diff: (!diff.is_empty()).then(|| diff.join("\n")),
        },
    ))
}

fn relative(path: &Path, folder: Option<&Path>) -> String {
    folder
        .and_then(|folder| path.strip_prefix(folder).ok())
        .filter(|relative| !relative.as_os_str().is_empty())
        .unwrap_or(path)
        .display()
        .to_string()
}

/// Paths one per line, the first 50 of a long list and a count of the rest.
fn path_list(paths: &[&std::path::PathBuf]) -> String {
    const SHOWN: usize = 50;
    let mut lines: Vec<String> = paths
        .iter()
        .take(SHOWN)
        .map(|path| path.display().to_string())
        .collect();
    if paths.len() > SHOWN {
        lines.push(format!("and {} more", paths.len() - SHOWN));
    }
    lines.join("\n")
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    use inline_agent_bridge::harness::{Interaction, InteractionKind};

    use super::golden::{Message, buttons};
    use super::{DecisionState, action_ids};
    use crate::bridge::v2::render::card_action;

    let interaction: Interaction =
        serde_json::from_value(input["interaction"].clone()).expect("interaction");
    let diffs: Vec<FileDiff> = serde_json::from_value(input["diffs"].clone()).unwrap_or_default();
    let agent = input["agent"].as_str().unwrap_or("Codex");
    let folder = input["folder"].as_str().map(Path::new);
    let InteractionKind::Approval { subject, decisions } = &interaction.kind else {
        panic!("an approval");
    };
    let actions: Vec<_> = decisions.iter().map(card_action).collect();
    let ids = action_ids(actions.len());
    let open = card(agent, subject, &diffs, folder, &ids, &Resolution::pending());
    let label = &actions[0].label;
    let closed = card(
        agent,
        subject,
        &diffs,
        folder,
        &ids,
        &Resolution::decided(
            DecisionState::Accepted,
            Some(7),
            format!("{label} (answered by Dena)"),
        ),
    );
    vec![
        Message::new("open", open, buttons(&ids, &actions)),
        Message::new("decided", closed, Vec::new()),
    ]
}
