import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";

type Document = { path: string; title: string; content: string; groundTruth: boolean; feedback: boolean };
type Theme = { id: string; title: string; patterns: RegExp[]; why: string };

const root = process.cwd();
const contextRoot = join(root, ".context");

async function walk(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    const rel = relative(contextRoot, path);
    if (entry.isDirectory()) {
      if (rel.startsWith("overnight-lab") || rel.startsWith("snapshots") || rel.startsWith("fundraising")) return [];
      return walk(path);
    }
    return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
  }));
  return nested.flat();
}

const themes: Theme[] = [
  { id: "realtime-recovery", title: "Realtime and sync must recover predictably", patterns: [/\brealtime\b/i, /\bsync\b/i, /reconnect/i, /getupdates/i, /websocket/i, /too_long/i, /sync cursor/i], why: "Core product correctness across every client and long-lived session." },
  { id: "fast-cached-ui", title: "Cached-first UI with no main-thread stalls", patterns: [/cached[- ]first/i, /main thread/i, /performance/i, /lag/i, /micro[- ]hang/i, /instant/i, /snapshot apply/i], why: "Repeated direct feedback on chat opening, lists, navigation, and perceived quality." },
  { id: "native-polish", title: "Native, simple, polished platform UX", patterns: [/native (?:control|button|menu|list|window|sheet|navigation|interaction|behavior)/i, /polish(?:ed)? (?:ui|ux|experience)/i, /simple (?:ui|ux|flow|design)/i, /swiftui/i, /uikit/i, /appkit/i, /telegram[- ](?:ios|style|inspired)/i], why: "A recurring acceptance standard for iOS and macOS feature work." },
  { id: "single-source-state", title: "One source of truth for shared state and actions", patterns: [/source of truth/i, /single owner/i, /shared.*policy/i, /duplicate(?:d)? (?:state|logic|view|owner|implementation)/i, /canonical (?:state|path|implementation|contract)/i, /consolidat/i], why: "Reduces drift across tabs, menus, clients, optimistic state, and backend-originated updates." },
  { id: "account-lifetime", title: "Account, session, and task ownership boundaries", patterns: [/logout/i, /relogin/i, /account switch/i, /old account/i, /runtime generation/i, /session (?:lifecycle|ownership|isolation|reset)/i, /cancel.*join/i], why: "Security and correctness boundary for durable work, observers, transports, and caches." },
  { id: "optimistic-transactions", title: "Fast optimistic actions with deterministic rollback", patterns: [/optimistic/i, /rollback/i, /open.*close/i, /pin.*unpin/i, /next[- ]frame/i, /latest intent/i, /transaction/i], why: "Repeated product goal for reactions, membership, sidebar actions, and offline behavior." },
  { id: "privacy-redaction", title: "Privacy-safe logs and minimum disclosure", patterns: [/privacy/i, /redact/i, /sensitive (?:data|query|content|value)/i, /secret/i, /auth token/i, /minimum.*disclosure/i, /public log/i], why: "Release-blocking trust requirement across logs, URLs, public spaces, and analytics." },
  { id: "error-recovery", title: "Typed errors, useful diagnostics, and self-recovery", patterns: [/error handling/i, /helpful error/i, /typed.*error/i, /error recovery/i, /retry/i, /error message/i, /diagnostic/i], why: "Repeated expectation that failures are safe, actionable, retryable, and observable." },
  { id: "agent-one-click", title: "One-command, end-to-end agent and bot setup", patterns: [/one command/i, /one[- ]click/i, /agents setup/i, /setup.*bot/i, /harness/i, /openclaw/i, /hermes/i, /codex/i], why: "Major product wedge spanning CLI, plugins, app UX, lifecycle, and verification." },
  { id: "bot-platform", title: "Bots and public integrations as first-class product surfaces", patterns: [/bot api/i, /bot[- ]to[- ]bot/i, /public (?:http )?api/i, /oauth/i, /\bmcp\b/i, /(?:agent|bot) plugin/i], why: "Repeated roadmap theme with public contracts, identity, discovery, and agent workflows." },
  { id: "release-proof", title: "Reproducible releases with crash/debug evidence", patterns: [/release/i, /testflight/i, /dSYM/i, /symbol/i, /xcode cloud/i, /sparkle/i, /notar/i, /provenance/i], why: "Old artifacts and dirty builds repeatedly failed to prove current source readiness." },
  { id: "real-tests", title: "Focused tests that prove real behavior", patterns: [/\btests?\b/i, /physical device/i, /production[- ]data/i, /smoke test/i, /test matrix/i, /fake host/i, /differential test/i], why: "Repeated preference for focused evidence over broad noisy or mock-only suites." },
  { id: "rollout-fallback", title: "Staged rollout, compatibility, and rollback", patterns: [/feature flag/i, /experimental toggle/i, /rollback/i, /backward compat/i, /staged/i, /fallback/i, /legacy/i], why: "Lets ambitious work ship without forcing unsafe all-at-once cutovers." },
  { id: "db-integrity", title: "Atomic durable state and database integrity", patterns: [/foreign key/i, /database/i, /grdb/i, /postgres/i, /atomic/i, /durable/i, /migration/i], why: "Core sync, transactions, auth, and history behavior depends on durable invariants." },
  { id: "bounded-lifetimes", title: "Bounded queues, caches, observers, and subprocesses", patterns: [/bounded (?:queue|cache|buffer|output|worker|concurrency)/i, /observer leak/i, /task leak/i, /deadlock/i, /timeout/i, /child process/i, /subprocess/i, /backpressure/i], why: "Repeated source of stalls, memory growth, deadlocks, and cross-account work." },
  { id: "navigation-discovery", title: "Unified navigation, sidebar, search, and commands", patterns: [/sidebar/i, /all chats/i, /inbox/i, /command bar/i, /cmd\+k/i, /search/i, /navigation/i], why: "Large repeated UX area across both Apple apps and feature discovery." },
  { id: "messages-compose", title: "Reliable compose, drafts, send, and message presentation", patterns: [/compose/i, /draft/i, /send message/i, /message bubble/i, /reply thread/i, /slash command/i], why: "The daily-use path has repeated correctness, animation, targeting, and layout feedback." },
  { id: "media-files", title: "Reliable media, uploads, previews, and document handling", patterns: [/file upload/i, /media send/i, /thumbnail/i, /attachment/i, /document preview/i, /photo upload/i, /video upload/i, /file download/i], why: "Cross-client path with latency, privacy, rendering, and failure-recovery implications." },
  { id: "grid-live", title: "Grid voice/video/transcription as a robust subsystem", patterns: [/grid/i, /livekit/i, /voice/i, /transcription/i, /screen shar/i, /audio/i], why: "Recurring differentiated feature with deployment, device, and realtime complexity." },
  { id: "shared-core", title: "Cross-platform shared packages and clear boundaries", patterns: [/shared package/i, /extract/i, /module boundar/i, /cross[- ]platform/i, /inlinekit/i, /reuse/i], why: "Repeated desire to consolidate behavior without creating speculative abstractions." },
  { id: "modernize-cleanup", title: "Modern APIs, cleanup, and removal of accidental complexity", patterns: [/modern/i, /deprecated/i, /obsolete/i, /cleanup/i, /refactor/i, /dead code/i, /new api/i], why: "Important hygiene theme, but must remain evidence-driven and compatibility-safe." },
  { id: "user-control", title: "Reversible, non-destructive user control", patterns: [/non[- ]destructive/i, /undo/i, /reversible/i, /do not delete/i, /clear history/i, /archive/i, /close/i], why: "Repeated product distinction between hiding, closing, archiving, clearing, and deletion." },
  { id: "operations-observability", title: "Safe operations and high-signal observability", patterns: [/observability/i, /production/i, /sentry/i, /metrics/i, /logs/i, /monitor/i, /health/i], why: "Needed to diagnose releases and services without leaking user data or drowning in noise." },
];

const files = await walk(contextRoot);
const documents: Document[] = await Promise.all(files.map(async (file) => {
  const content = await readFile(file, "utf8");
  const path = relative(root, file);
  const title = content.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? path;
  return {
    path,
    title,
    content,
    groundTruth: /ground[- ]truth/i.test(path) || /ground truth/i.test(title),
    feedback: /feedback/i.test(path) || /^##+\s+.*(feedback|requirements|goal)/im.test(content),
  };
}));

function matches(theme: Theme, content: string): boolean {
  return theme.patterns.some((pattern) => pattern.test(content));
}

function quoteCandidates(theme: Theme, docs: Document[]): Array<{ path: string; quote: string }> {
  const candidates: Array<{ path: string; quote: string }> = [];
  for (const doc of docs) {
    for (const line of doc.content.split(/\r?\n/)) {
      const bullet = line.match(/^\s*-\s+(.+)/)?.[1]?.trim();
      if (!bullet || bullet.length < 24 || bullet.length > 260 || !matches(theme, bullet)) continue;
      candidates.push({ path: doc.path, quote: bullet.replaceAll("|", "\\|") });
      break;
    }
  }
  return candidates.slice(0, 6);
}

const results = themes.map((theme) => {
  const all = documents.filter((doc) => matches(theme, `${doc.title}\n${doc.content}`));
  const groundTruth = all.filter((doc) => doc.groundTruth);
  const feedback = all.filter((doc) => doc.feedback);
  const score = groundTruth.length * 5 + feedback.length * 2 + Math.min(all.length, 100) * 0.2;
  return { ...theme, all: all.length, groundTruth: groundTruth.length, feedback: feedback.length, score, sources: groundTruth.slice(0, 12).map((doc) => doc.path), quotes: quoteCandidates(theme, groundTruth) };
}).sort((a, b) => b.score - a.score || b.groundTruth - a.groundTruth || a.title.localeCompare(b.title));

const lines = [
  "# Repeated Ground Truth, Feedback, and Project Goals",
  "",
  `Corpus: ${documents.length} context documents, including ${documents.filter((doc) => doc.groundTruth).length} ground-truth documents and ${documents.filter((doc) => doc.feedback).length} documents with explicit feedback/requirements/goal sections.`,
  "",
  "> Counts are discovery signals, not a product vote. Generic words can inflate a theme; sources and current code still determine whether a work item is valid.",
  "",
  "## Ranked repeated themes",
  "",
  "| Rank | Theme | Ground truth docs | Feedback/goal docs | All context docs | Why it matters |",
  "|---:|---|---:|---:|---:|---|",
  ...results.map((item, index) => `| ${index + 1} | ${item.title} | ${item.groundTruth} | ${item.feedback} | ${item.all} | ${item.why} |`),
  "",
  "## Evidence by theme",
  "",
  ...results.flatMap((item, index) => [
    `### ${index + 1}. ${item.title}`,
    "",
    `Signal: ${item.groundTruth} ground-truth docs, ${item.feedback} feedback/goal docs, ${item.all} context docs.`,
    "",
    ...item.quotes.map((quote) => `- “${quote.quote.replace(/^['“]|['”]$/g, "")}” — \`${quote.path}\``),
    "",
    "Representative sources:",
    "",
    ...item.sources.map((source) => `- \`${source}\``),
    "",
  ]),
];

await Bun.write(join(root, ".context/overnight-lab/02-repeated-ground-truth-patterns.md"), `${lines.join("\n")}\n`);
await Bun.write(join(root, ".context/overnight-lab/02-repeated-ground-truth-patterns.json"), `${JSON.stringify(results, null, 2)}\n`);

console.log(JSON.stringify({ documents: documents.length, groundTruth: documents.filter((doc) => doc.groundTruth).length, feedback: documents.filter((doc) => doc.feedback).length, top: results.slice(0, 10).map((item) => ({ id: item.id, groundTruth: item.groundTruth, all: item.all })) }));
