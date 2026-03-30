# Codex Skills Backlog: 90/10 + Prevent Tech Debt + Lets Work Together (2026-02-07)

From notes (Feb 4-7, 2026): "skill: 90/10", "skill: tech-debt cleaner", "small: create skill prevent-tech-debt, 90/10, lets-work-together".

This doc is a specification for new skills, not an implementation of the skills themselves.

## Goals

1. Encode your working style into repeatable prompts so “momentum days” are easier.
2. Reduce accidental scope creep and cleanup debt.
3. Make collaboration with agents more consistent (handoffs, checklists, definitions of done).

## Skill 1: `90-10`

Intent:
1. Push towards the simplest shippable path.
2. Explicitly call out “the last 10%” and defer it safely.

When to use:
1. Planning a feature with multiple approaches.
2. You feel stuck in analysis or perfectionism.

Skill behavior:
1. Ask for the user-visible outcome and the minimum acceptance criteria.
2. Propose a “90% version” that is safe to ship.
3. List the 10% polish items and label them explicitly as optional.
4. Identify the one risk that can invalidate the 90% plan.

Output template:
1. Problem statement
2. 90% plan
3. 10% backlog
4. Risks and mitigations
5. Tests and smoke checks

## Skill 2: `prevent-tech-debt`

Intent:
1. Ship quickly but avoid leaving behind sharp edges that slow tomorrow.

When to use:
1. After implementing a feature (pre-commit / pre-PR).
2. When code changes span multiple packages or clients.

Skill behavior:
1. Scan for common debt patterns:
2. Debug prints/log spam
3. Dead code paths and TODOs introduced by the change
4. Unsafe Swift patterns (`!`, `try!`, forced casts)
5. Inconsistent naming and missing tests
6. Unbounded retries/backoffs

2. Produce a checklist of “must fix before merge” vs “ok to defer”.
3. Recommend the smallest set of tests to run.

Output template:
1. High risk issues
2. Medium risk issues
3. Defer list
4. Tests to run

## Skill 3: `lets-work-together`

Intent:
1. Improve coordination in multi-agent / multi-human sessions.

When to use:
1. Large tasks where multiple agents will touch adjacent areas.
2. When you want crisp handoffs for tomorrow morning.

Skill behavior:
1. Produce a short shared plan with explicit ownership:
2. Files per agent/person
3. Interfaces/contracts to agree on first
4. Order of operations

2. Define a “stop condition” to avoid two agents doing the same thing.
3. Produce a “handoff note” format:
4. What changed
5. What is risky
6. What’s next

## Proposed Installation

1. Create skill directories under `.codex/skills/<skill-name>/SKILL.md`.
2. Keep each SKILL.md short and procedural (avoid essays).
3. Include at least one example invocation.

## Acceptance Criteria

1. Using `90-10` produces a plan you can implement same-day with explicit deferrals.
2. Using `prevent-tech-debt` catches regressions before they ship.
3. Using `lets-work-together` reduces duplicate work in multi-agent sessions.

