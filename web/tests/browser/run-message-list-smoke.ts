import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"
import { resizeObserverErrorSuppressionScript } from "../../src/platform/browser/BrowserResizeObserverErrors"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  await page.navigate(appOrigin)
  const harnessDocument = `<!doctype html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <link rel="stylesheet" href="${appOrigin}/src/styles/base.css" />
        <script>
          ${resizeObserverErrorSuppressionScript}
          window.inlineMessageListHarnessErrors = []
          window.addEventListener("error", (event) => {
            window.inlineMessageListHarnessErrors.push(
              event.error?.stack ?? event.message ?? "unknown browser error"
            )
          })
          window.addEventListener("unhandledrejection", (event) => {
            window.inlineMessageListHarnessErrors.push(
              event.reason?.stack ?? String(event.reason)
            )
          })
        </script>
      </head>
      <body>
        <main id="message-list-harness-root"></main>
        <script type="module">
          await Promise.all(
            Array.from(document.querySelectorAll('link[rel="stylesheet"]')).map(
              (link) => link.sheet
                ? Promise.resolve()
                : new Promise((resolve, reject) => {
                    link.addEventListener("load", resolve, { once: true })
                    link.addEventListener("error", () => reject(
                      new Error("Could not load browser harness stylesheet: " + link.href)
                    ), { once: true })
                  })
            )
          )
          import RefreshRuntime from "${appOrigin}/@react-refresh"
          RefreshRuntime.injectIntoGlobalHook(window)
          window.$RefreshReg$ = () => {}
          window.$RefreshSig$ = () => (type) => type
          window.__vite_plugin_react_preamble_installed__ = true
          await import("${appOrigin}/src/testing/benchmarks/MessageListBrowserHarnessPage.ts")
        </script>
      </body>
    </html>`
  const harnessUrl = await page.evaluate<string>(`URL.createObjectURL(
    new Blob([${JSON.stringify(harnessDocument)}], { type: "text/html" })
  )`)
  await page.navigate(harnessUrl)
  const result = await page.evaluate(`(async () => {
    const root = document.querySelector("#message-list-harness-root")
    const frames = (count = 8) => new Promise((resolve) => {
      const next = () => count-- > 0
        ? requestAnimationFrame(next)
        : resolve()
      requestAnimationFrame(next)
    })
    const require = (condition, message) => {
      if (!condition) throw new Error(message)
    }
    const waitForHarness = async () => {
      const deadline = performance.now() + 10_000
      while (!window.inlineMessageListHarnessReady) {
        if (performance.now() >= deadline) {
          throw new Error("message-list harness did not initialize: " + JSON.stringify({
            errors: window.inlineMessageListHarnessErrors,
            resources: performance.getEntriesByType("resource").map((entry) => ({
              name: entry.name,
              duration: entry.duration,
              transferSize: entry.transferSize
            })),
            body: document.body?.innerText
          }))
        }
        await frames(1)
      }
      return window.inlineMessageListHarnessReady
    }
    const results = {}
    let harness = await waitForHarness()
    await frames()

    results.initial = harness.metrics()
    results.chatOpenTrace = harness.chatOpenTrace()
    require(
      results.chatOpenTrace?.outcome === "painted",
      "chat-open trace did not reach first paint: " + JSON.stringify(results.chatOpenTrace)
    )
    require(
      results.chatOpenTrace.renderedMessageCount === 200 &&
        results.chatOpenTrace.firstPaintMs >= results.chatOpenTrace.firstLayoutMs &&
        results.chatOpenTrace.firstLayoutMs >= results.chatOpenTrace.projectionReadyMs,
      "chat-open trace milestones are inconsistent: " + JSON.stringify(results.chatOpenTrace)
    )
    require(
      performance.getEntriesByName("inline.chat-open.first-paint").length === 1,
      "chat-open first-paint measure was not published"
    )
    results.composerClearance = harness.composerClearance()
    require(
      results.composerClearance >= -1,
      "message viewport extends behind composer: " + JSON.stringify({
        clearance: results.composerClearance,
        metrics: results.initial
      })
    )
    results.contentFallback = document.body.innerText.includes("Voice message")
    require(
      results.contentFallback,
      "protocol media rendered as an empty timestamp-only bubble"
    )
    const lateAttachmentBefore = harness.rowGeometry("1193")
    require(
      lateAttachmentBefore && document.body.innerText.includes("Unsupported message"),
      "late-attachment base message did not render its honest fallback"
    )
    harness.applyPreviewAttachment("1193")
    await frames(12)
    results.lateAttachment = {
      before: lateAttachmentBefore,
      after: harness.rowGeometry("1193"),
      rendered: document.body.innerText.includes("Late Inline preview"),
      metrics: harness.metrics(),
      composerClearance: harness.composerClearance()
    }
    require(
      results.lateAttachment.rendered,
      "post-message attachment update did not render: " + JSON.stringify(results.lateAttachment)
    )
    require(
      results.lateAttachment.metrics.distanceToBottom <= 18 &&
        results.lateAttachment.composerClearance >= -1,
      "attachment update broke bottom/composer geometry: " + JSON.stringify(results.lateAttachment)
    )
    results.replyRows = {
      embedded: document.body.innerText.includes("Inline message 1190"),
      summary: document.body.innerText.includes("3 replies") &&
        document.body.innerText.includes("Reply thread"),
      unread: Boolean(document.querySelector('[aria-label="Unread replies"]'))
    }
    require(
      results.replyRows.embedded && results.replyRows.summary && results.replyRows.unread,
      "embedded reply or reply-thread summary did not render: " + JSON.stringify({
        ...results.replyRows,
        initial: results.initial,
        chatOpenTrace: results.chatOpenTrace,
        tail: document.body.innerText.slice(-1200),
        mounted: Array.from(document.querySelectorAll('[data-message-id]')).map((row) => row.dataset.messageId)
      })
    )
    const previewBefore = harness.rowGeometry("1196")
    const taskBefore = harness.rowGeometry("1197")
    await frames(12)
    const previewAfter = harness.rowGeometry("1196")
    const taskAfter = harness.rowGeometry("1197")
    results.attachmentRows = {
      urlPreview: document.body.innerText.includes("Inline for work") &&
        document.body.innerText.includes("Fast, focused team communication"),
      externalTask: document.body.innerText.includes("Fix message list") &&
        document.body.innerText.includes("Dena created a Linear issue"),
      previewBefore,
      previewAfter,
      taskBefore,
      taskAfter
    }
    require(
      results.attachmentRows.urlPreview && results.attachmentRows.externalTask,
      "known protocol attachments did not render: " + JSON.stringify(results.attachmentRows)
    )
    require(
      previewBefore && previewAfter && taskBefore && taskAfter &&
        Math.abs(previewBefore.height - previewAfter.height) <= 1 &&
        Math.abs(taskBefore.height - taskAfter.height) <= 1,
      "attachment hydration changed row geometry: " + JSON.stringify(results.attachmentRows)
    )
    results.forwardHeader = document.body.innerText.includes("Forwarded from: Dena")
    require(
      results.forwardHeader,
      "forward header did not resolve its normalized Inline source"
    )
    document.querySelector('button[aria-label="Forwarded from: Dena"]')?.click()
    require(
      harness.forwardOpenCount() === 1,
      "same-peer forward header did not use bounded message navigation"
    )
    const reactionChip = document.querySelector('button[aria-label="👍, 2 reactions"]')
    results.reactions = {
      rendered: Boolean(reactionChip),
      height: harness.rowGeometry("1194")?.height
    }
    require(
      results.reactions.rendered,
      "native-derived reaction chip did not render: " + JSON.stringify(results.reactions)
    )
    reactionChip.click()
    require(
      harness.reactionMutationCount() === 1,
      "reaction chip did not dispatch through the realtime transaction boundary"
    )
    if (results.initial.distanceToBottom > 18) {
      const viewport = document.querySelector('[data-inline-message-list="viewport"]')
      const beforeRawClamp = harness.metrics()
      viewport.scrollTop = viewport.scrollHeight
      const afterRawClamp = harness.metrics()
      await frames(2)
      const afterRawFrames = harness.metrics()
      throw new Error("initial list is not bottom attached: " + JSON.stringify({
        beforeRawClamp,
        afterRawClamp,
        afterRawFrames,
        viewportStyle: {
          overflowY: getComputedStyle(viewport).overflowY,
          height: getComputedStyle(viewport).height,
          position: getComputedStyle(viewport).position
        },
        viewportRect: viewport.getBoundingClientRect().toJSON(),
        errors: window.inlineMessageListHarnessErrors
      }))
    }
    require(
      results.initial.distanceToBottom <= 18,
      "initial list is not bottom attached: " + JSON.stringify(results.initial)
    )
    require(
      harness.bottomState() === true,
      "message list did not report its initial bottom state"
    )

    require(harness.jumpTo("1151"), "unread-boundary target was rejected")
    await frames(12)
    require(
      document.querySelector('[aria-label="Unread messages"]'),
      "unread boundary did not render before the first unread message"
    )
    require(
      harness.bottomState() === false,
      "centered message jump did not leave bottom state"
    )
    await harness.scrollToRatio(1)
    await frames(12)
    require(
      harness.bottomState() === true,
      "imperative bottom navigation did not restore bottom state"
    )

    harness.resize(320)
    await frames()
    results.resizeAtBottom = harness.metrics()
    require(
      results.resizeAtBottom.distanceToBottom <= 18,
      "window resize lost bottom attachment: " + JSON.stringify({
        initial: results.initial,
        resized: results.resizeAtBottom
      })
    )
    require(
      harness.composerClearance() >= -1,
      "window resize moved message viewport behind composer"
    )

    await harness.scrollToRatio(0.45)
    const afterScrollToRatio = harness.metrics()
    await frames()
    const beforePrependMetrics = harness.metrics()
    require(
      beforePrependMetrics.distanceToBottom > 18,
      "scroll-up setup did not leave bottom: " + JSON.stringify({
        afterScrollToRatio,
        afterFrames: beforePrependMetrics
      })
    )
    require(
      harness.bottomState() === false,
      "user scroll-up did not leave bottom state"
    )
    const beforePrepend = harness.visibleAnchor()
    require(
      beforePrepend,
      "prepend test has no visible anchor: " + JSON.stringify({
        metrics: harness.metrics(),
        root: {
          rect: root.getBoundingClientRect().toJSON(),
          style: root.getAttribute("style")
        },
        viewport: (() => {
          const element = document.querySelector('[data-inline-message-list="viewport"]')
          return element ? {
            rect: element.getBoundingClientRect().toJSON(),
            style: getComputedStyle(element).cssText,
            className: element.className
          } : null
        })(),
        rows: Array.from(document.querySelectorAll("[data-message-id]"))
          .slice(0, 8)
          .map((row) => {
            const rect = row.getBoundingClientRect()
            return { id: row.dataset.messageId, top: rect.top, bottom: rect.bottom }
          })
      })
    )
    harness.prepend(50)
    await frames(12)
    const afterPrepend = harness.visibleAnchor()
    const afterPrependMetrics = harness.metrics()
    results.prepend = {
      before: beforePrepend,
      after: afterPrepend,
      beforeMetrics: beforePrependMetrics,
      afterMetrics: afterPrependMetrics
    }
    require(
      afterPrepend?.messageId === beforePrepend.messageId,
      "prepend changed visible anchor: " + JSON.stringify(results.prepend)
    )
    require(
      Math.abs(afterPrepend.top - beforePrepend.top) <= 2,
      "prepend moved visible anchor: " + JSON.stringify(results.prepend)
    )

    harness.append(false)
    await frames()
    const afterIncoming = harness.visibleAnchor()
    results.incomingWhileUp = { before: afterPrepend, after: afterIncoming }
    require(
      afterIncoming?.messageId === afterPrepend.messageId,
      "incoming message stole scrolled-up position: " + JSON.stringify({
        before: afterPrepend,
        after: afterIncoming,
        prepend: results.prepend,
        metrics: harness.metrics()
      })
    )
    require(
      Math.abs(afterIncoming.top - afterPrepend.top) <= 2,
      "incoming message moved scrolled-up anchor: " + JSON.stringify({
        before: afterPrepend,
        after: afterIncoming,
        metrics: harness.metrics()
      })
    )

    harness.trimStart(20)
    await frames(12)
    const afterTrimStart = harness.visibleAnchor()
    results.trimStart = { before: afterIncoming, after: afterTrimStart }
    require(
      afterTrimStart?.messageId === afterIncoming.messageId &&
        Math.abs(afterTrimStart.top - afterIncoming.top) <= 2,
      "start compaction moved visible anchor: " + JSON.stringify(results.trimStart)
    )

    harness.slideForward(20)
    await frames(12)
    const afterSlideForward = harness.visibleAnchor()
    results.slideForward = { before: afterTrimStart, after: afterSlideForward }
    require(
      afterSlideForward?.messageId === afterTrimStart.messageId &&
        Math.abs(afterSlideForward.top - afterTrimStart.top) <= 2,
      "forward window slide moved visible anchor: " + JSON.stringify(results.slideForward)
    )

    harness.trimEnd(10)
    await frames(12)
    const afterTrimEnd = harness.visibleAnchor()
    results.trimEnd = { before: afterSlideForward, after: afterTrimEnd }
    require(
      afterTrimEnd?.messageId === afterSlideForward.messageId &&
        Math.abs(afterTrimEnd.top - afterSlideForward.top) <= 2,
      "end compaction moved visible anchor: " + JSON.stringify(results.trimEnd)
    )

    await harness.scrollToRatio(1)
    await frames()
    harness.expandLast()
    await frames(12)
    results.dynamicBottomResize = harness.metrics()
    require(
      results.dynamicBottomResize.distanceToBottom <= 18,
      "dynamic bottom-row resize lost bottom attachment: " + JSON.stringify(results.dynamicBottomResize)
    )

    await harness.scrollToRatio(0.4)
    await frames()
    harness.append(true)
    await frames(12)
    results.outgoing = harness.metrics()
    require(results.outgoing.distanceToBottom <= 18, "outgoing message did not force bottom")

    const mediaLoadsBeforePhoto = harness.mediaLoadCount()
    const photoMessageId = harness.appendPhoto(true)
    const coldPhotoRow = document.querySelector(
      '[data-message-id="' + photoMessageId + '"]'
    )
    const coldFullPhoto = coldPhotoRow?.querySelector('img[alt="Photo"]')
    const coldTinyPhoto = coldPhotoRow?.querySelector('img[aria-hidden="true"]')
    results.photoFirstCommit = {
      fullSource: coldFullPhoto?.getAttribute("src"),
      hasTinyThumbnail: Boolean(coldTinyPhoto),
      geometry: harness.rowGeometry(photoMessageId),
      mediaLoadCount: harness.mediaLoadCount(),
      mediaLoadsBeforePhoto
    }
    require(
      !results.photoFirstCommit.fullSource &&
        results.photoFirstCommit.hasTinyThumbnail &&
        results.photoFirstCommit.geometry,
      "uncached photo bypassed its stable tiny-thumbnail first commit: " +
        JSON.stringify(results.photoFirstCommit)
    )
    const waitForFullPhoto = async () => {
      for (let attempt = 0; attempt < 120; attempt += 1) {
        const image = document.querySelector(
          '[data-message-id="' + photoMessageId + '"] img[alt="Photo"]'
        )
        if (image?.complete && image.naturalWidth > 0) return image
        await frames(1)
      }
      throw new Error("owner-managed photo did not decode")
    }
    const photo = await waitForFullPhoto()
    const photoBeforeDecode = harness.rowGeometry(photoMessageId)
    require(photoBeforeDecode, "photo row did not mount")
    require(
      photo.getAttribute("src")?.startsWith("blob:"),
      "photo did not render owner-provided cached bytes"
    )
    require(
      harness.mediaLoadCount() === mediaLoadsBeforePhoto + 1,
      "photo acquisition did not use one owner-held byte load: " +
        harness.mediaLoadCount()
    )
    await frames(12)
    const photoAfterDecode = harness.rowGeometry(photoMessageId)
    results.photoGeometry = { before: photoBeforeDecode, after: photoAfterDecode }
    require(photoBeforeDecode.height >= 230, "photo did not reserve protocol dimensions")
    require(
      photoAfterDecode && Math.abs(photoAfterDecode.height - photoBeforeDecode.height) <= 2,
      "decoded media changed reserved row height: " + JSON.stringify(results.photoGeometry)
    )
    require(
      harness.metrics().distanceToBottom <= 18,
      "decoded media lost bottom attachment"
    )
    const warmSource = photo.getAttribute("src")
    const warmBefore = harness.rowGeometry(photoMessageId)
    harness.navigateAwayAndBack()
    // Virtua installs its measured item range during layout work after the
    // keyed remount. Sample in the first rAF callback: React/layout updates
    // have settled, but the browser has not painted that animation frame yet.
    await frames(0)
    const warmPhoto = document.querySelector(
      '[data-message-id="' + photoMessageId + '"] img[alt="Photo"]'
    )
    const warmFirstFrame = {
      source: warmPhoto?.getAttribute("src"),
      geometry: harness.rowGeometry(photoMessageId),
      metrics: harness.metrics(),
      mediaLoadCount: harness.mediaLoadCount()
    }
    require(
      warmFirstFrame.source === warmSource &&
        warmFirstFrame.geometry &&
        warmBefore &&
        Math.abs(warmFirstFrame.geometry.height - warmBefore.height) <= 2 &&
        warmFirstFrame.metrics.distanceToBottom <= 18 &&
        warmFirstFrame.mediaLoadCount === mediaLoadsBeforePhoto + 1,
      "warm chat remount did not reuse stable cached media in its first frame: " +
        JSON.stringify({ warmBefore, warmFirstFrame })
    )
    await frames(12)
    results.photoWarmRemount = {
      firstFrame: warmFirstFrame,
      settledGeometry: harness.rowGeometry(photoMessageId),
      settledMetrics: harness.metrics(),
      mediaLoadCount: harness.mediaLoadCount()
    }
    require(
      results.photoWarmRemount.settledGeometry &&
        Math.abs(
          results.photoWarmRemount.settledGeometry.height -
          warmFirstFrame.geometry.height
        ) <= 2 &&
        results.photoWarmRemount.settledMetrics.distanceToBottom <= 18 &&
        results.photoWarmRemount.mediaLoadCount === mediaLoadsBeforePhoto + 1,
      "warm cached media shifted or reloaded after first paint: " +
        JSON.stringify(results.photoWarmRemount)
    )

    require(harness.jumpTo("1050"), "loaded jump target was rejected")
    await frames(12)
    const jumpTarget = harness.rowGeometry("1050")
    results.jumpToMessage = jumpTarget
    require(jumpTarget, "jump target was not virtualized into view")
    require(
      Math.abs(((jumpTarget.top + jumpTarget.bottom) / 2) - jumpTarget.viewportMiddle) <= 24,
      "jump target was not centered: " + JSON.stringify(jumpTarget)
    )
    require(
      document.querySelector('[data-message-id="1050"]')?.dataset.highlighted === "true",
      "jump target was not highlighted"
    )

    await harness.scrollToRatio(0.35)
    await frames()
    const beforeNavigation = harness.visibleAnchor()
    require(beforeNavigation, "navigation test has no visible anchor")
    harness.unmount()
    harness = await window.inlineMessageListHarness.mount({
      resetScrollState: false
    })
    await frames(12)
    const afterNavigation = harness.visibleAnchor()
    results.navigation = { before: beforeNavigation, after: afterNavigation }
    require(
      afterNavigation?.messageId === beforeNavigation.messageId,
      "navigation restore changed anchor: " + JSON.stringify(results.navigation)
    )
    require(
      Math.abs(afterNavigation.top - beforeNavigation.top) <= 2,
      "navigation restore moved anchor: " + JSON.stringify(results.navigation)
    )

    await harness.scrollToRatio(0.35)
    await frames()
    const sendingMessageId = harness.replaceWithSending()
    await frames(12)
    results.sendFromOldWindow = {
      messageId: sendingMessageId,
      geometry: harness.rowGeometry(sendingMessageId),
      metrics: harness.metrics(),
      bottomState: harness.bottomState()
    }
    require(
      results.sendFromOldWindow.geometry &&
        results.sendFromOldWindow.metrics.distanceToBottom <= 18 &&
        results.sendFromOldWindow.bottomState === true,
      "outgoing send did not switch a replaced old window to bottom: " +
        JSON.stringify(results.sendFromOldWindow)
    )
    harness.failLast()
    await frames(4)
    results.failedResend = {
      action: Boolean(document.querySelector(
        'button[aria-label="Resend message"]'
      )),
      before: harness.resendCount()
    }
    harness.clickResend()
    await frames(4)
    results.failedResend.after = harness.resendCount()
    results.failedResend.sending = Boolean(document.querySelector(
      '[aria-label="Sending"]'
    ))
    require(
      results.failedResend.action &&
        results.failedResend.before === 0 &&
        results.failedResend.after === 1 &&
        results.failedResend.sending,
      "failed message did not expose and execute native Resend: " +
        JSON.stringify(results.failedResend)
    )
    await harness.sendCompose("Accepted browser send")
    await frames(12)
    results.composeAcceptance = {
      text: harness.composeText(),
      mutationCount: harness.reactionMutationCount()
    }
    require(
      results.composeAcceptance.text === "",
      "compose cleared before/without owner acceptance or failed to clear after acceptance: " +
        JSON.stringify(results.composeAcceptance)
    )
    harness.unmount()
    await frames(2)
    results.browserErrors = window.inlineMessageListHarnessErrors
    require(
      results.browserErrors.length === 0,
      "message-list browser errors: " + JSON.stringify(results.browserErrors)
    )
    return results
  })()`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  await page.close()
}
