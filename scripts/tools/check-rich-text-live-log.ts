type LogSeverity = "warning" | "blocker"

export type RichTextLogIssue = {
  severity: LogSeverity
  message: string
  line?: number
}

export type RichTextMediaFailure = {
  line: number
  kind: string
  host: string
}

export type RichTextLiveLogReport = {
  lineCount: number
  richMediaResolvedCount: number
  richMediaFailureCount: number
  richMediaDegradationCount: number
  richMediaFailureBackoffCount: number
  fileUploadCompletedCount: number
  fileUploadsByType: Record<string, number>
  sendRichMessageDraftCount: number
  updateRichMessageDraftCount: number
  chatgptLogCount: number
  chatgptRichFinalDeliveryCount: number
  openclawLogCount: number
  openclawRichFinalDeliveryCount: number
  openclawDraftFallbackCount: number
  mediaResolvedByKey: Record<string, number>
  mediaFailuresByKey: Record<string, number>
  mediaDegradationsByKey: Record<string, number>
  issues: RichTextLogIssue[]
  ok: boolean
}

type AnalyzeOptions = {
  repeatedFailureThreshold?: number
  requireLiveSignals?: boolean
  requireOpenClawSignals?: boolean
  requireMediaUpload?: boolean
  strictMedia?: boolean
}

type OutputFormat = "text" | "markdown"

export type RichTextLiveLogCliOptions = {
  help: boolean
  errors: string[]
  outputFormat: OutputFormat
  paths: string[]
  requireLiveSignals: boolean
  requireMediaUpload: boolean
  requireOpenClawSignals: boolean
  strictMedia: boolean
}

const DEFAULT_REPEATED_FAILURE_THRESHOLD = 1

export function analyzeRichTextLiveLog(input: string, options: AnalyzeOptions = {}): RichTextLiveLogReport {
  const lines = input.split(/\r?\n/)
  const mediaResolved: RichTextMediaFailure[] = []
  const mediaFailures: RichTextMediaFailure[] = []
  const mediaDegradations: RichTextMediaFailure[] = []
  const issues: RichTextLogIssue[] = []
  const repeatedFailureThreshold = options.repeatedFailureThreshold ?? DEFAULT_REPEATED_FAILURE_THRESHOLD
  let richMediaFailureBackoffCount = 0
  const fileUploadsByType: Record<string, number> = {}
  let sendRichMessageDraftCount = 0
  let updateRichMessageDraftCount = 0
  let chatgptLogCount = 0
  let chatgptRichFinalDeliveryCount = 0
  let openclawLogCount = 0
  let openclawRichFinalDeliveryCount = 0
  let openclawDraftFallbackCount = 0

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? ""
    const lineNumber = index + 1
    const block = lines.slice(index, index + 12).join("\n")

    if (line.includes("Resolved rich media public URL")) {
      const block = lines.slice(index, index + 16).join("\n")
      mediaResolved.push({
        line: lineNumber,
        kind: extractField(block, "kind") ?? "unknown",
        host: extractField(block, "urlHost") ?? "unknown",
      })
    }

    if (line.includes("Failed to resolve rich media public URL")) {
      const block = lines.slice(index, index + 16).join("\n")
      mediaFailures.push({
        line: lineNumber,
        kind: extractField(block, "kind") ?? "unknown",
        host: extractField(block, "urlHost") ?? "unknown",
      })
    }

    if (line.includes("Degraded rich media public URL to fallback")) {
      const block = lines.slice(index, index + 16).join("\n")
      mediaDegradations.push({
        line: lineNumber,
        kind: extractField(block, "kind") ?? "unknown",
        host: extractField(block, "urlHost") ?? "unknown",
      })
    }

    if (line.includes("Skipping rich media public URL during failure backoff")) {
      richMediaFailureBackoffCount += 1
    }

    if (line.includes("File uploaded to bucket successfully")) {
      const block = lines.slice(index, index + 8).join("\n")
      const fileType = extractField(block, "fileType") ?? "unknown"
      fileUploadsByType[fileType] = (fileUploadsByType[fileType] ?? 0) + 1
    }

    if (line.includes("sendRichMessageDraft")) {
      sendRichMessageDraftCount += 1
    }

    if (line.includes("UpdateRichMessageDraft")) {
      updateRichMessageDraftCount += 1
    }

    if (line.includes("chatgpt.run") || line.includes("chatgpt.codex")) {
      chatgptLogCount += 1
    }

    if (/ChatGPT final rich delivery/i.test(line) && extractBooleanField(block, "parseRichMarkdown") === true) {
      chatgptRichFinalDeliveryCount += 1
    }

    if (/openclaw|inline progress (draft|placeholder)|inline edit stream|inline media upload|inline dispatch/i.test(line)) {
      openclawLogCount += 1
    }

    if (/openclaw inline rich final delivery/i.test(line) && hasOpenClawFinalRichDeliveryFlag(block)) {
      openclawRichFinalDeliveryCount += 1
    }

    if (/progress draft failed|draft unavailable|falling back to editMessage/i.test(line)) {
      openclawDraftFallbackCount += 1
    }

    const isDraftValidationLine =
      /rich message drafts cannot contain unresolved public media|draft_id is required|RichTextValidationError/i.test(line)
    if (isDraftValidationLine) {
      issues.push({
        severity: "blocker",
        line: lineNumber,
        message: "Rich draft validation error appeared in live logs.",
      })
    }

    if (!isDraftValidationLine && /unresolved public (rich )?media/i.test(line)) {
      issues.push({
        severity: "blocker",
        line: lineNumber,
        message: "Final rich output appears to contain unresolved public media.",
      })
    }
  }

  const mediaResolvedByKey = countMediaFailures(mediaResolved)
  const mediaFailuresByKey = countMediaFailures(mediaFailures)
  const mediaDegradationsByKey = countMediaFailures(mediaDegradations)
  for (const [key, count] of Object.entries(mediaFailuresByKey)) {
    if (count > repeatedFailureThreshold) {
      issues.push({
        severity: "blocker",
        message: `Repeated rich media public URL resolution failure for ${key}: ${count} warnings.`,
      })
    }
  }
  for (const [key, count] of Object.entries(mediaDegradationsByKey)) {
    if (count > repeatedFailureThreshold) {
      issues.push({
        severity: "blocker",
        message: `Repeated rich media public URL degradation for ${key}: ${count} fallbacks.`,
      })
    }
  }

  if (options.strictMedia && mediaFailures.length > 0) {
    issues.push({
      severity: "blocker",
      message: `Rich media public URL resolution failed ${mediaFailures.length} time(s); beta live media gate expects zero failed public URLs.`,
    })
  } else if (mediaFailures.length > 0) {
    issues.push({
      severity: "warning",
      message: `Rich media public URL resolution failed ${mediaFailures.length} time(s); use --strict-media for beta live media gating.`,
    })
  }

  if (options.strictMedia && mediaDegradations.length > 0) {
    issues.push({
      severity: "blocker",
      message: `Rich media public URL degraded to fallback ${mediaDegradations.length} time(s); beta live media gate expects uploaded media.`,
    })
  } else if (mediaDegradations.length > 0) {
    issues.push({
      severity: "warning",
      message: `Rich media public URL degraded to fallback ${mediaDegradations.length} time(s); use --strict-media for beta live media gating.`,
    })
  }

  if (options.strictMedia && richMediaFailureBackoffCount > 0) {
    issues.push({
      severity: "blocker",
      message: `Rich media public URL backoff skipped ${richMediaFailureBackoffCount} URL(s); beta live media gate expects fresh resolvable media.`,
    })
  }

  const fileUploadCompletedCount = Object.values(fileUploadsByType).reduce((sum, count) => sum + count, 0)
  if (options.requireMediaUpload && fileUploadCompletedCount === 0) {
    issues.push({
      severity: "blocker",
      message: "No completed file upload was found; confirm the image/media smoke prompt produced uploaded rich media.",
    })
  }
  if (options.requireMediaUpload && options.strictMedia && mediaResolved.length === 0) {
    issues.push({
      severity: "blocker",
      message: "No resolved rich media public URL was found; completed uploads may be unrelated to rich text media.",
    })
  }

  if (sendRichMessageDraftCount === 0 && updateRichMessageDraftCount === 0) {
    issues.push({
      severity: options.requireLiveSignals ? "blocker" : "warning",
      message: "No rich draft signal was found; confirm the log includes the streaming window.",
    })
  }

  if (chatgptLogCount === 0) {
    issues.push({
      severity: options.requireLiveSignals ? "blocker" : "warning",
      message: "No ChatGPT run signal was found; confirm the log includes the ChatGPT smoke prompt.",
    })
  }
  if (chatgptLogCount > 0 && chatgptRichFinalDeliveryCount === 0) {
    issues.push({
      severity: options.requireLiveSignals ? "blocker" : "warning",
      message: "No ChatGPT final rich delivery signal was found; confirm final send/edit used rich Markdown.",
    })
  }

  if (openclawDraftFallbackCount > 0) {
    issues.push({
      severity: "warning",
      message: `OpenClaw draft fallback appeared ${openclawDraftFallbackCount} time(s); verify this was expected.`,
    })
  }

  if (openclawLogCount === 0) {
    issues.push({
      severity: options.requireOpenClawSignals ? "blocker" : "warning",
      message: "No OpenClaw log signal was found; confirm the OpenClaw gateway log is included for the OpenClaw live pass.",
    })
  }
  if (openclawLogCount > 0 && openclawRichFinalDeliveryCount === 0) {
    issues.push({
      severity: options.requireOpenClawSignals ? "blocker" : "warning",
      message: "No OpenClaw final rich delivery signal was found; confirm final send/edit used rich Markdown or structured rich text.",
    })
  }

  const hasBlocker = issues.some((issue) => issue.severity === "blocker")
  return {
    lineCount: lines.length,
    richMediaResolvedCount: mediaResolved.length,
    richMediaFailureCount: mediaFailures.length,
    richMediaDegradationCount: mediaDegradations.length,
    richMediaFailureBackoffCount,
    fileUploadCompletedCount,
    fileUploadsByType,
    sendRichMessageDraftCount,
    updateRichMessageDraftCount,
    chatgptLogCount,
    chatgptRichFinalDeliveryCount,
    openclawLogCount,
    openclawRichFinalDeliveryCount,
    openclawDraftFallbackCount,
    mediaResolvedByKey,
    mediaFailuresByKey,
    mediaDegradationsByKey,
    issues,
    ok: !hasBlocker,
  }
}

function extractField(block: string, field: string): string | undefined {
  const match = new RegExp(`"?${field}"?\\s*:\\s*"([^"]+)"`).exec(block)
  return match?.[1]
}

function extractBooleanField(block: string, field: string): boolean | undefined {
  const pattern = new RegExp(`"?${field}"?\\s*(?::|=)\\s*(true|false)`, "i")
  const match = pattern.exec(block)
  if (!match) {
    return undefined
  }
  return match[1]?.toLowerCase() === "true"
}

function hasRichDeliveryFlag(block: string): boolean {
  return extractBooleanField(block, "parseRichMarkdown") === true || extractBooleanField(block, "richText") === true
}

function hasOpenClawFinalRichDeliveryFlag(block: string): boolean {
  if (!hasRichDeliveryFlag(block)) {
    return false
  }

  const phase = extractTokenField(block, "phase")
  if (phase === undefined) {
    return true
  }

  return phase === "final" || phase === "reply" || phase === "media-caption"
}

function extractTokenField(block: string, field: string): string | undefined {
  const pattern = new RegExp(`"?${field}"?\\s*(?::|=)\\s*"?([A-Za-z0-9_-]+)"?`, "i")
  const match = pattern.exec(block)
  return match?.[1]?.toLowerCase()
}

function countMediaFailures(failures: RichTextMediaFailure[]): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const failure of failures) {
    const key = `${failure.kind}@${failure.host}`
    counts[key] = (counts[key] ?? 0) + 1
  }
  return counts
}

export function formatRichTextLiveLogReport(report: RichTextLiveLogReport): string {
  const lines = [
    `rich text live log check ${report.ok ? "ok" : "failed"}`,
    `lines=${report.lineCount}`,
    `rich_media_resolved=${report.richMediaResolvedCount}`,
    `rich_media_failures=${report.richMediaFailureCount}`,
    `rich_media_degradations=${report.richMediaDegradationCount}`,
    `rich_media_backoff_skips=${report.richMediaFailureBackoffCount}`,
    `file_uploads_completed=${report.fileUploadCompletedCount}`,
    `send_rich_message_draft=${report.sendRichMessageDraftCount}`,
    `update_rich_message_draft=${report.updateRichMessageDraftCount}`,
    `chatgpt_logs=${report.chatgptLogCount}`,
    `chatgpt_rich_final_deliveries=${report.chatgptRichFinalDeliveryCount}`,
    `openclaw_logs=${report.openclawLogCount}`,
    `openclaw_rich_final_deliveries=${report.openclawRichFinalDeliveryCount}`,
    `openclaw_draft_fallbacks=${report.openclawDraftFallbackCount}`,
  ]

  const resolvedMediaKeys = Object.entries(report.mediaResolvedByKey)
  if (resolvedMediaKeys.length > 0) {
    lines.push("media_resolved_by_key:")
    for (const [key, count] of resolvedMediaKeys) {
      lines.push(`  ${key}: ${count}`)
    }
  }

  const mediaKeys = Object.entries(report.mediaFailuresByKey)
  if (mediaKeys.length > 0) {
    lines.push("media_failures_by_key:")
    for (const [key, count] of mediaKeys) {
      lines.push(`  ${key}: ${count}`)
    }
  }

  const degradedMediaKeys = Object.entries(report.mediaDegradationsByKey)
  if (degradedMediaKeys.length > 0) {
    lines.push("media_degradations_by_key:")
    for (const [key, count] of degradedMediaKeys) {
      lines.push(`  ${key}: ${count}`)
    }
  }

  const uploads = Object.entries(report.fileUploadsByType)
  if (uploads.length > 0) {
    lines.push("file_uploads_by_type:")
    for (const [type, count] of uploads) {
      lines.push(`  ${type}: ${count}`)
    }
  }

  if (report.issues.length > 0) {
    lines.push("issues:")
    for (const issue of report.issues) {
      const location = issue.line === undefined ? "" : ` line ${issue.line}:`
      lines.push(`  ${issue.severity}:${location} ${issue.message}`)
    }
  }

  return lines.join("\n")
}

export function formatRichTextLiveLogMarkdown(report: RichTextLiveLogReport, paths: string[] = []): string {
  const status = report.ok ? "Pass" : "Blocker"
  const lines = [
    "### Rich Text Live Log Check",
    "",
    `- Result: ${status}`,
    `- Log artifact: ${paths.length === 0 ? "" : paths.join(", ")}`,
    `- Lines: ${report.lineCount}`,
    `- Rich media resolved: ${report.richMediaResolvedCount}`,
    `- Rich media failures: ${report.richMediaFailureCount}`,
    `- Rich media degradations: ${report.richMediaDegradationCount}`,
    `- Rich media backoff skips: ${report.richMediaFailureBackoffCount}`,
    `- File uploads completed: ${report.fileUploadCompletedCount}`,
    `- sendRichMessageDraft signals: ${report.sendRichMessageDraftCount}`,
    `- UpdateRichMessageDraft signals: ${report.updateRichMessageDraftCount}`,
    `- ChatGPT log signals: ${report.chatgptLogCount}`,
    `- ChatGPT final rich deliveries: ${report.chatgptRichFinalDeliveryCount}`,
    `- OpenClaw log signals: ${report.openclawLogCount}`,
    `- OpenClaw final rich deliveries: ${report.openclawRichFinalDeliveryCount}`,
    `- OpenClaw draft fallback warnings: ${report.openclawDraftFallbackCount}`,
  ]

  const resolvedMediaKeys = Object.entries(report.mediaResolvedByKey)
  if (resolvedMediaKeys.length > 0) {
    lines.push("", "Media resolved keys:")
    for (const [key, count] of resolvedMediaKeys) {
      lines.push(`- ${key}: ${count}`)
    }
  }

  const mediaKeys = Object.entries(report.mediaFailuresByKey)
  if (mediaKeys.length > 0) {
    lines.push("", "Media failure keys:")
    for (const [key, count] of mediaKeys) {
      lines.push(`- ${key}: ${count}`)
    }
  }

  const degradedMediaKeys = Object.entries(report.mediaDegradationsByKey)
  if (degradedMediaKeys.length > 0) {
    lines.push("", "Media degradation keys:")
    for (const [key, count] of degradedMediaKeys) {
      lines.push(`- ${key}: ${count}`)
    }
  }

  const uploads = Object.entries(report.fileUploadsByType)
  if (uploads.length > 0) {
    lines.push("", "File uploads by type:")
    for (const [type, count] of uploads) {
      lines.push(`- ${type}: ${count}`)
    }
  }

  if (report.issues.length > 0) {
    lines.push("", "Issues:")
    for (const issue of report.issues) {
      const location = issue.line === undefined ? "" : ` line ${issue.line}:`
      lines.push(`- ${issue.severity}:${location} ${issue.message}`)
    }
  }

  return lines.join("\n")
}

export function parseRichTextLiveLogArgs(args: string[]): RichTextLiveLogCliOptions {
  const options: RichTextLiveLogCliOptions = {
    help: false,
    errors: [],
    outputFormat: "text",
    paths: [],
    requireLiveSignals: false,
    requireMediaUpload: false,
    requireOpenClawSignals: false,
    strictMedia: false,
  }

  for (const arg of args) {
    switch (arg) {
      case "--help":
      case "-h":
        options.help = true
        break
      case "--markdown":
        options.outputFormat = "markdown"
        break
      case "--strict-signals":
        options.requireLiveSignals = true
        break
      case "--strict-media":
        options.strictMedia = true
        break
      case "--require-media-upload":
        options.requireMediaUpload = true
        break
      case "--require-openclaw-signals":
        options.requireOpenClawSignals = true
        break
      default:
        if (arg.startsWith("--")) {
          options.errors.push(`unknown argument: ${arg}`)
        } else {
          options.paths.push(arg)
        }
        break
    }
  }

  if (!options.help && options.paths.length === 0) {
    options.errors.push("at least one log file is required")
  }

  return options
}

async function main(args: string[]): Promise<number> {
  const options = parseRichTextLiveLogArgs(args)
  if (options.help) {
    printUsage()
    return 0
  }
  if (options.errors.length > 0) {
    for (const error of options.errors) {
      console.error(error)
    }
    printUsage()
    return 2
  }

  let input = ""
  for (const path of options.paths) {
    input += await Bun.file(path).text()
    input += "\n"
  }

  const report = analyzeRichTextLiveLog(input, {
    requireLiveSignals: options.requireLiveSignals,
    requireMediaUpload: options.requireMediaUpload,
    requireOpenClawSignals: options.requireOpenClawSignals,
    strictMedia: options.strictMedia,
  })
  console.log(
    options.outputFormat === "markdown"
      ? formatRichTextLiveLogMarkdown(report, options.paths)
      : formatRichTextLiveLogReport(report),
  )
  return report.ok ? 0 : 1
}

function printUsage(): void {
  console.log(
    "usage: bun run tools/check-rich-text-live-log.ts [--markdown] [--strict-signals] [--strict-media] [--require-media-upload] [--require-openclaw-signals] <log-file> [log-file ...]",
  )
}

if (import.meta.main) {
  const code = await main(process.argv.slice(2))
  process.exit(code)
}
