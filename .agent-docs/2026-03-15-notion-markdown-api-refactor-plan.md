# Notion Markdown API Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Inline's Notion task creation flow from legacy block JSON to Notion's markdown page API while keeping existing saved Notion selections working in production.

**Architecture:** Keep the existing integration record field for backward compatibility, but reinterpret it as a Notion parent selection that can hold either a legacy database ID or a newer data source ID. Resolve the active data source at runtime, fetch schema/sample rows from the latest Notion API, have the AI return `properties + markdown`, and create the page with the `markdown` body parameter instead of `children`.

**Tech Stack:** Bun, TypeScript, OpenAI structured outputs, Notion REST API, `@notionhq/client`

---

## Chunk 1: Compatibility Layer

### Task 1: Add failing tests for Notion parent resolution and markdown response parsing

**Files:**
- Create: `server/src/modules/notion/notionMarkdown.test.ts`
- Modify: `server/src/modules/notion/agentResponse.test.ts`

- [ ] **Step 1: Write failing tests**
- [ ] **Step 2: Run the focused tests and verify they fail**
- [ ] **Step 3: Implement the minimal compatibility helpers**
- [ ] **Step 4: Re-run the focused tests and verify they pass**

### Task 2: Resolve legacy database IDs into active data sources

**Files:**
- Modify: `server/src/modules/notion/notion.ts`
- Modify: `server/src/db/models/integrations.ts`

- [ ] **Step 1: Add a latest-version Notion client helper**
- [ ] **Step 2: Add a resolver that accepts saved legacy IDs and returns `{ databaseId, dataSourceId, dataSource, database }`**
- [ ] **Step 3: Preserve backward compatibility for existing integration rows**
- [ ] **Step 4: Add telemetry for ambiguous multi-data-source cases**

## Chunk 2: Markdown Content Path

### Task 3: Change the AI contract from block arrays to markdown

**Files:**
- Modify: `server/src/modules/notion/agentResponse.ts`
- Modify: `server/src/modules/notion/agentResponse.test.ts`
- Modify: `server/src/modules/notion/prompts.ts`
- Modify: `server/src/modules/notion/agent.ts`

- [ ] **Step 1: Write the failing parser tests for `markdown` output**
- [ ] **Step 2: Update the structured output schema to `properties + markdown + icon`**
- [ ] **Step 3: Update the prompt so it explicitly targets valid enhanced markdown**
- [ ] **Step 4: Remove the legacy block transformation path**

### Task 4: Create pages with Notion markdown

**Files:**
- Modify: `server/src/modules/notion/notion.ts`
- Modify: `server/src/modules/notion/agent.ts`

- [ ] **Step 1: Add a markdown page creation helper using the latest Notion API**
- [ ] **Step 2: Pass `markdown` instead of `children` when creating the task page**
- [ ] **Step 3: Keep property handling and title extraction intact**
- [ ] **Step 4: Log markdown size and parent identifiers for diagnostics**

## Chunk 3: Selection and Sample Context

### Task 5: Return selectable data sources instead of legacy database containers

**Files:**
- Modify: `server/src/methods/notion/getNotionDatabases.ts`
- Modify: `server/src/modules/notion/notion.ts`
- Modify: `server/src/methods/notion/saveNotionDatabaseId.ts`

- [ ] **Step 1: List data sources from Notion using the latest API**
- [ ] **Step 2: Keep the existing RPC response shape but return data source IDs**
- [ ] **Step 3: Clarify labels for multi-source databases**
- [ ] **Step 4: Keep the save RPC contract stable for clients**

### Task 6: Feed sample markdown back into the prompt

**Files:**
- Modify: `server/src/modules/notion/notion.ts`
- Modify: `server/src/modules/notion/agent.ts`

- [ ] **Step 1: Retrieve sample page markdown via `GET /pages/:page_id/markdown`**
- [ ] **Step 2: Trim sample content to keep token usage controlled**
- [ ] **Step 3: Update the prompt context to show markdown examples instead of raw block payloads**

## Chunk 4: Verification

### Task 7: Run focused validation for the Notion refactor

**Files:**
- Modify: `server/package.json` if the SDK needs to be upgraded
- Modify: `bun.lock` if dependencies change

- [ ] **Step 1: Run focused Notion module tests**
- [ ] **Step 2: Run a focused server typecheck or document unrelated blockers**
- [ ] **Step 3: Review the final diff for production risks**

