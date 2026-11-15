//! Claude `ExitPlanMode`, Codex proposed plans: a plan to approve before the
//! agent acts.
//!
//! Claude asks through a permission request, so its buttons are the
//! interaction's own decisions ("Yes" reads Approve, "No" reads Keep
//! planning). Codex ends a Plan mode turn with a `plan` item and its app asks
//! "Implement this plan?" itself; here that is the card's [`APPROVE`] (leave
//! Plan mode and send "Implement the plan.") and [`KEEP_PLANNING`].

use inline_agent_bridge::harness::{Decision, DecisionKind};
use inline_protocol::proto;

use super::{Resolution, markdown};
use crate::bridge::v2::doc::{Doc, DocBuilder};
use crate::bridge::v2::render::{ActionStyle, CardAction};

/// Codex's approve button: leave Plan mode and implement.
pub(crate) const APPROVE: &str = "plan-approve";
/// Codex's keep-planning button.
pub(crate) const KEEP_PLANNING: &str = "plan-keep";
/// What Codex's own app sends when a plan is approved.
pub(crate) const IMPLEMENT_MESSAGE: &str = "Implement the plan.";

pub(crate) const APPROVE_LABEL: &str = "Approve";
pub(crate) const KEEP_PLANNING_LABEL: &str = "Keep planning";

/// Claude's plan decisions as the card's buttons: approve first and primary,
/// its "auto-accept edits" choices as Claude words them, keep planning last.
pub(crate) fn actions(decisions: &[Decision]) -> Vec<CardAction> {
    decisions
        .iter()
        .map(|decision| match decision.kind {
            DecisionKind::Accept => CardAction {
                decision: decision.id.to_string(),
                label: APPROVE_LABEL.to_owned(),
                style: ActionStyle::Primary,
            },
            DecisionKind::Decline | DecisionKind::Cancel => CardAction {
                decision: decision.id.to_string(),
                label: KEEP_PLANNING_LABEL.to_owned(),
                style: ActionStyle::Default,
            },
            _ => CardAction {
                decision: decision.id.to_string(),
                label: decision.label.clone(),
                style: ActionStyle::Default,
            },
        })
        .collect()
}

/// The plan card. A plan that opens with a heading takes it as its title.
pub(crate) fn card(agent: &str, plan: &str, action_ids: &[String], resolution: &Resolution) -> Doc {
    let mut builder = DocBuilder::new();
    let plan = plan.trim();
    let (title, body) = match plan.split_once('\n') {
        Some((first, rest)) if first.starts_with("# ") => (first[2..].trim().to_owned(), rest),
        None if plan.starts_with("# ") => (plan[2..].trim().to_owned(), ""),
        _ => (format!("{agent}'s plan"), plan),
    };
    let title = builder.span(&title);
    let children = builder.nested(|inner| markdown::write(inner, body));
    builder.push_block(proto::block::Kind::PlanProposal(proto::BlockPlanProposal {
        title: Some(title),
        children,
        state: resolution.state as i32,
        action_ids: resolution.action_ids(action_ids),
        decided_by_user_id: resolution.by,
        is_rtl: None,
    }));
    resolution.write_note(&mut builder);
    builder.finish()
}

#[cfg(test)]
pub(super) fn sample(input: &serde_json::Value) -> Vec<super::golden::Message> {
    use inline_agent_bridge::harness::{ApprovalSubject, Interaction, InteractionKind};

    use super::golden::{Message, buttons};
    use super::{DecisionState, action_ids};

    // A whole turn through the renderer.
    if input.get("events").is_some() {
        return super::golden::rendered(input);
    }
    // A Claude approval, or a Codex plan item's text.
    if let Ok(interaction) = serde_json::from_value::<Interaction>(input.clone())
        && let InteractionKind::Approval {
            subject: ApprovalSubject::Plan { plan },
            decisions,
        } = &interaction.kind
    {
        let actions = actions(decisions);
        let ids = action_ids(actions.len());
        let open = card("Claude", plan, &ids, &Resolution::pending());
        let approved = card(
            "Claude",
            plan,
            &ids,
            &Resolution::decided(
                DecisionState::Accepted,
                Some(7),
                "Approve (answered by Dena)",
            ),
        );
        return vec![
            Message::new("open", open, buttons(&ids, &actions)),
            Message::new("approved", approved, Vec::new()),
        ];
    }
    let plan = input["text"].as_str().expect("plan text");
    let ids = [APPROVE.to_owned(), KEEP_PLANNING.to_owned()];
    let codex = [
        CardAction {
            decision: APPROVE.to_owned(),
            label: APPROVE_LABEL.to_owned(),
            style: ActionStyle::Primary,
        },
        CardAction {
            decision: KEEP_PLANNING.to_owned(),
            label: KEEP_PLANNING_LABEL.to_owned(),
            style: ActionStyle::Default,
        },
    ];
    let open = card("Codex", plan, &ids, &Resolution::pending());
    let kept = card(
        "Codex",
        plan,
        &ids,
        &Resolution::decided(DecisionState::Declined, Some(7), "Kept planning (Dena)"),
    );
    vec![
        Message::new("open", open, buttons(&ids, &codex)),
        Message::new("kept planning", kept, Vec::new()),
    ]
}
