import { describe, expect, test } from "bun:test"

import {
  analyzeRichTextLiveLog,
  formatRichTextLiveLogMarkdown,
  formatRichTextLiveLogReport,
  parseRichTextLiveLogArgs,
} from "./check-rich-text-live-log"

describe("rich text live log checker", () => {
  test("parses strict live log CLI options", () => {
    const options = parseRichTextLiveLogArgs([
      "--markdown",
      "--strict-signals",
      "--strict-media",
      "--require-media-upload",
      "--require-openclaw-signals",
      "../.tmp/rich-text-live-server.log",
      "../.tmp/rich-text-live-openclaw.log",
    ])

    expect(options.errors).toEqual([])
    expect(options.outputFormat).toBe("markdown")
    expect(options.paths).toEqual(["../.tmp/rich-text-live-server.log", "../.tmp/rich-text-live-openclaw.log"])
    expect(options.requireLiveSignals).toBe(true)
    expect(options.requireMediaUpload).toBe(true)
    expect(options.requireOpenClawSignals).toBe(true)
    expect(options.strictMedia).toBe(true)
  })

  test("rejects unknown CLI flags", () => {
    const options = parseRichTextLiveLogArgs(["--strict-meida", "../.tmp/rich-text-live-server.log"])

    expect(options.errors).toContain("unknown argument: --strict-meida")
  })

  test("requires at least one log path unless help was requested", () => {
    expect(parseRichTextLiveLogArgs([]).errors).toContain("at least one log file is required")
    expect(parseRichTextLiveLogArgs(["--help"]).errors).toEqual([])
  })

  test("passes a log with draft and ChatGPT signals", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc publish UpdateRichMessageDraft",
        "rpc call sendRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "modules/mediaUploader Skipping rich media public URL during failure backoff",
      ].join("\n"),
    )

    expect(report.ok).toBe(true)
    expect(report.sendRichMessageDraftCount).toBe(1)
    expect(report.updateRichMessageDraftCount).toBe(1)
    expect(report.chatgptLogCount).toBe(1)
    expect(report.openclawLogCount).toBe(1)
  })

  test("flags repeated rich media public URL resolution warnings by media kind and host", () => {
    const report = analyzeRichTextLiveLog(
      [
        "modules/mediaUploader Failed to resolve rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "commons.wikimedia.org",',
        "}",
        "chatgpt.codex ChatGPT Codex response completed",
        "rpc publish UpdateRichMessageDraft",
        "modules/mediaUploader Failed to resolve rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "commons.wikimedia.org",',
        "}",
      ].join("\n"),
    )

    expect(report.ok).toBe(false)
    expect(report.mediaFailuresByKey["photo@commons.wikimedia.org"]).toBe(2)
    expect(report.issues.some((issue) => issue.severity === "blocker")).toBe(true)
  })

  test("does not collapse different media kinds into the same repeated failure", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/mediaUploader Failed to resolve rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "example.com",',
        "}",
        "modules/mediaUploader Failed to resolve rich media public URL {",
        '  kind: "document",',
        '  urlHost: "example.com",',
        "}",
      ].join("\n"),
    )

    expect(report.ok).toBe(true)
    expect(report.mediaFailuresByKey["photo@example.com"]).toBe(1)
    expect(report.mediaFailuresByKey["document@example.com"]).toBe(1)
    expect(report.issues.some((issue) => issue.severity === "warning" && issue.message.includes("--strict-media"))).toBe(
      true,
    )
  })

  test("strict media mode fails on a single public URL resolution failure", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/mediaUploader Failed to resolve rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "example.com",',
        "}",
      ].join("\n"),
      { strictMedia: true },
    )

    expect(report.ok).toBe(false)
    expect(report.richMediaFailureCount).toBe(1)
    expect(report.issues.some((issue) => issue.severity === "blocker" && issue.message.includes("zero failed public URLs"))).toBe(true)
  })

  test("tracks degraded public URL media separately from resolver failures", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/mediaUploader Degraded rich media public URL to fallback {",
        '  kind: "photo",',
        '  urlHost: "example.com",',
        "}",
      ].join("\n"),
    )

    expect(report.ok).toBe(true)
    expect(report.richMediaFailureCount).toBe(0)
    expect(report.richMediaDegradationCount).toBe(1)
    expect(report.mediaDegradationsByKey["photo@example.com"]).toBe(1)
    expect(formatRichTextLiveLogReport(report)).toContain("rich_media_degradations=1")
    expect(formatRichTextLiveLogReport(report)).toContain("media_degradations_by_key:")
  })

  test("strict media mode fails on degraded public URL media", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/mediaUploader Degraded rich media public URL to fallback {",
        '  kind: "photo",',
        '  urlHost: "example.com",',
        "}",
      ].join("\n"),
      { strictMedia: true },
    )

    expect(report.ok).toBe(false)
    expect(report.richMediaDegradationCount).toBe(1)
    expect(report.issues.some((issue) => issue.severity === "blocker" && issue.message.includes("degraded to fallback"))).toBe(true)
  })

  test("strict media mode fails on public URL backoff skips", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc publish UpdateRichMessageDraft",
        "modules/mediaUploader Skipping rich media public URL during failure backoff",
      ].join("\n"),
      { strictMedia: true },
    )

    expect(report.ok).toBe(false)
    expect(report.richMediaFailureBackoffCount).toBe(1)
    expect(report.issues.some((issue) => issue.severity === "blocker" && issue.message.includes("backoff skipped"))).toBe(true)
  })

  test("counts completed file uploads by type", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/files/uploadAFile File uploaded to bucket successfully {",
        '  fileType: "photo",',
        "}",
        "modules/files/uploadAFile File uploaded to bucket successfully {",
        '  fileType: "document",',
        "}",
      ].join("\n"),
    )

    expect(report.ok).toBe(true)
    expect(report.fileUploadCompletedCount).toBe(2)
    expect(report.fileUploadsByType.photo).toBe(1)
    expect(report.fileUploadsByType.document).toBe(1)
    expect(formatRichTextLiveLogReport(report)).toContain("file_uploads_by_type:")
  })

  test("counts resolved rich media public URLs by media kind and host", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "modules/mediaUploader Resolved rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "images.example.com",',
        "}",
      ].join("\n"),
    )

    expect(report.ok).toBe(true)
    expect(report.richMediaResolvedCount).toBe(1)
    expect(report.mediaResolvedByKey["photo@images.example.com"]).toBe(1)
    expect(formatRichTextLiveLogReport(report)).toContain("rich_media_resolved=1")
    expect(formatRichTextLiveLogReport(report)).toContain("media_resolved_by_key:")
    expect(formatRichTextLiveLogMarkdown(report)).toContain("- Rich media resolved: 1")
    expect(formatRichTextLiveLogMarkdown(report)).toContain("Media resolved keys:")
  })

  test("media upload requirement fails when no upload completed", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
      ].join("\n"),
      { requireLiveSignals: true, requireMediaUpload: true, requireOpenClawSignals: true },
    )

    expect(report.ok).toBe(false)
    expect(report.issues.some((issue) => issue.severity === "blocker" && issue.message.includes("No completed file upload"))).toBe(true)
  })

  test("strict media upload requirement rejects unrelated uploads without rich media resolver success", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "openclaw inline rich final delivery phase=final method=send parseRichMarkdown=true richText=false messageId=10",
        "modules/files/uploadAFile File uploaded to bucket successfully {",
        '  fileType: "photo",',
        "}",
      ].join("\n"),
      { requireLiveSignals: true, requireMediaUpload: true, requireOpenClawSignals: true, strictMedia: true },
    )

    expect(report.ok).toBe(false)
    expect(report.fileUploadCompletedCount).toBe(1)
    expect(report.richMediaResolvedCount).toBe(0)
    expect(report.issues.some((issue) => issue.severity === "blocker" && issue.message.includes("No resolved rich media public URL"))).toBe(true)
  })

  test("media upload requirement passes when a rich public URL resolved and an upload completed", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "openclaw inline rich final delivery phase=final method=send parseRichMarkdown=true richText=false messageId=10",
        "modules/mediaUploader Resolved rich media public URL {",
        '  kind: "photo",',
        '  urlHost: "images.example.com",',
        "}",
        "modules/files/uploadAFile File uploaded to bucket successfully {",
        '  fileType: "photo",',
        "}",
      ].join("\n"),
      { requireLiveSignals: true, requireMediaUpload: true, requireOpenClawSignals: true, strictMedia: true },
    )

    expect(report.ok).toBe(true)
    expect(report.fileUploadCompletedCount).toBe(1)
    expect(report.richMediaResolvedCount).toBe(1)
  })

  test("flags rich draft validation errors", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        "RichTextValidationError: rich message drafts cannot contain unresolved public media",
      ].join("\n"),
    )

    expect(report.ok).toBe(false)
    expect(formatRichTextLiveLogReport(report)).toContain("Rich draft validation error")
    expect(formatRichTextLiveLogReport(report)).not.toContain("Final rich output")
  })

  test("parses JSON-style structured log fields", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc call sendRichMessageDraft",
        'modules/mediaUploader Failed to resolve rich media public URL {"kind":"photo","urlHost":"example.com"}',
        'modules/mediaUploader Failed to resolve rich media public URL {"kind":"photo","urlHost":"example.com"}',
      ].join("\n"),
    )

    expect(report.ok).toBe(false)
    expect(report.mediaFailuresByKey["photo@example.com"]).toBe(2)
  })

  test("formats a paste-ready markdown review note", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc publish UpdateRichMessageDraft",
        "rpc call sendRichMessageDraft",
        "openclaw inline progress placeholder updated",
      ].join("\n"),
    )
    const markdown = formatRichTextLiveLogMarkdown(report, [".tmp/rich-text-live-server.log"])

    expect(markdown).toContain("### Rich Text Live Log Check")
    expect(markdown).toContain("- Result: Pass")
    expect(markdown).toContain("- Log artifact: .tmp/rich-text-live-server.log")
  })

  test("strict signal mode fails when the log does not include live ChatGPT or draft evidence", () => {
    const report = analyzeRichTextLiveLog("", { requireLiveSignals: true })

    expect(report.ok).toBe(false)
    expect(report.issues.filter((issue) => issue.severity === "blocker")).toHaveLength(2)
  })

  test("strict signal mode passes when ChatGPT and draft evidence are present", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
        "rpc publish UpdateRichMessageDraft",
      ].join("\n"),
      { requireLiveSignals: true },
    )

    expect(report.ok).toBe(true)
  })

  test("OpenClaw signal requirement fails only when explicitly requested", () => {
    const input = [
      "chatgpt.run ChatGPT turn succeeded",
      "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
      "rpc publish UpdateRichMessageDraft",
    ].join("\n")

    expect(analyzeRichTextLiveLog(input, { requireLiveSignals: true }).ok).toBe(true)
    const required = analyzeRichTextLiveLog(input, { requireLiveSignals: true, requireOpenClawSignals: true })

    expect(required.ok).toBe(false)
    expect(required.issues.some((issue) => issue.message.includes("No OpenClaw log signal"))).toBe(true)
  })

  test("OpenClaw signal requirement passes when gateway-shaped evidence is present", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "openclaw inline rich final delivery phase=final method=send parseRichMarkdown=true richText=false messageId=10",
      ].join("\n"),
      { requireLiveSignals: true, requireOpenClawSignals: true },
    )

    expect(report.ok).toBe(true)
    expect(formatRichTextLiveLogReport(report)).toContain("openclaw_logs=2")
    expect(formatRichTextLiveLogReport(report)).toContain("openclaw_rich_final_deliveries=1")
  })

  test("strict signal mode rejects generic ChatGPT/OpenClaw logs without final rich delivery evidence", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
      ].join("\n"),
      { requireLiveSignals: true, requireOpenClawSignals: true },
    )

    expect(report.ok).toBe(false)
    expect(report.issues.some((issue) => issue.message.includes("No ChatGPT final rich delivery signal"))).toBe(true)
    expect(report.issues.some((issue) => issue.message.includes("No OpenClaw final rich delivery signal"))).toBe(true)
  })

  test("counts multiline structured final rich delivery logs", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery {",
        "  parseRichMarkdown: true,",
        "  delivery: \"send\",",
        "}",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "openclaw inline rich final delivery {",
        "  parseRichMarkdown: false,",
        "  richText: true,",
        "  method: \"edit\",",
        "}",
      ].join("\n"),
      { requireLiveSignals: true, requireOpenClawSignals: true },
    )

    expect(report.ok).toBe(true)
    expect(report.chatgptRichFinalDeliveryCount).toBe(1)
    expect(report.openclawRichFinalDeliveryCount).toBe(1)
  })

  test("does not count non-final OpenClaw rich helper logs as final delivery", () => {
    const report = analyzeRichTextLiveLog(
      [
        "chatgpt.run ChatGPT turn succeeded",
        "chatgpt.run ChatGPT final rich delivery { parseRichMarkdown: true, delivery: \"edit\" }",
        "rpc publish UpdateRichMessageDraft",
        "openclaw inline progress placeholder updated",
        "openclaw inline rich final delivery phase=callback method=edit parseRichMarkdown=true richText=false messageId=10",
        "openclaw inline rich final delivery phase=stream method=edit parseRichMarkdown=true richText=false messageId=10",
        "openclaw inline rich final delivery phase=error-fallback method=send parseRichMarkdown=true richText=false messageId=11",
      ].join("\n"),
      { requireLiveSignals: true, requireOpenClawSignals: true },
    )

    expect(report.ok).toBe(false)
    expect(report.openclawRichFinalDeliveryCount).toBe(0)
    expect(report.issues.some((issue) => issue.message.includes("No OpenClaw final rich delivery signal"))).toBe(true)
  })
})
