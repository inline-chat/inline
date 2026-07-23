// Preserved for comparison while the remaining CDP harnesses migrate. The
// supported owner contract is tests/browser/specs/core-owner.pw.ts.
import { ChromeDevtoolsPage } from "../ChromeDevtoolsPage"

const debuggerOrigin =
  process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const pages: ChromeDevtoolsPage[] = []

const openPage = async () => {
  const page = await ChromeDevtoolsPage.open(debuggerOrigin)
  pages.push(page)
  // Use one stable same-origin execution context for every renderer. Separate
  // blob documents receive distinct storage keys and therefore cannot prove
  // real SharedWorker identity/ownership across tabs.
  await page.navigate(`${appOrigin}/@vite/client`)
  await page.evaluate(`(async () => {
    await import(
      "${appOrigin}/src/testing/core/InlineCoreOwnerBrowserHarnessPage.ts"
    )
    const deadline = performance.now() + 5_000
    while (!window.inlineCoreOwnerHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline core owner harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)
  return page
}

try {
  const first = await openPage()
  const second = await openPage()
  const [firstOwner, secondOwner] = await Promise.all([
    first.evaluate<string>(
      `window.inlineCoreOwnerHarness.connect("first-tab")`,
    ),
    second.evaluate<string>(
      `window.inlineCoreOwnerHarness.connect("second-tab")`,
    ),
  ])
  if (firstOwner !== secondOwner) {
    throw new Error(
      `Two tabs created different Inline owners: ${firstOwner} / ${secondOwner}`,
    )
  }
  const crossVersionResult = await first.evaluate<string>(
    `window.inlineCoreOwnerHarness.connectDifferentGeneration("future-tab", "future")`,
  )
  if (
    !crossVersionResult.includes("owner-failed") ||
    !crossVersionResult.includes("Another Inline version")
  ) {
    throw new Error(
      `A second SharedWorker generation was not fenced: ${crossVersionResult}`,
    )
  }
  const [firstPhase, secondPhase] = await Promise.all([
    first.evaluate<string>(
      `window.inlineCoreOwnerHarness.waitForCacheReady("first-tab")`,
    ),
    second.evaluate<string>(
      `window.inlineCoreOwnerHarness.waitForCacheReady("second-tab")`,
    ),
  ])

  const draftText = "Shared browser draft"
  await first.evaluate(
    `window.inlineCoreOwnerHarness.updateDraft("first-tab", ${JSON.stringify(draftText)})`,
  )
  const secondDraft = await second.evaluate<string | undefined>(
    `window.inlineCoreOwnerHarness.loadDraftText("second-tab")`,
  )
  if (secondDraft !== draftText) {
    throw new Error(
      `Second renderer did not project the owner draft: ${JSON.stringify(secondDraft)}`,
    )
  }

  const revision = await second.evaluate<number>(
    `window.inlineCoreOwnerHarness.requestProjection("second-tab")`,
  )
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new Error(
      `Shared owner returned an invalid projection revision: ${revision}`,
    )
  }

  await first.evaluate(
    `window.inlineCoreOwnerHarness.detach("first-tab")`,
  )
  const revisionAfterPeerDetach = await second.evaluate<number>(
    `window.inlineCoreOwnerHarness.requestProjection("second-tab")`,
  )
  if (revisionAfterPeerDetach < revision) {
    throw new Error(
      `Projection revision moved backwards after peer detach: ${revision} -> ${revisionAfterPeerDetach}`,
    )
  }

  const third = await openPage()
  const thirdOwner = await third.evaluate<string>(
    `window.inlineCoreOwnerHarness.connect("third-tab")`,
  )
  if (thirdOwner !== firstOwner) {
    throw new Error(
      `Owner was replaced while attached clients remained: ${firstOwner} -> ${thirdOwner}`,
    )
  }
  const thirdDraft = await third.evaluate<string | undefined>(
    `window.inlineCoreOwnerHarness.loadDraftText("third-tab")`,
  )
  if (thirdDraft !== draftText) {
    throw new Error(
      `Warm renderer did not reuse the owner draft: ${JSON.stringify(thirdDraft)}`,
    )
  }

  await Promise.all([
    second.evaluate(
      `window.inlineCoreOwnerHarness.detach("second-tab")`,
    ),
    third.evaluate(
      `window.inlineCoreOwnerHarness.detach("third-tab")`,
    ),
  ])

  // Production keeps the account owner warm for 30 seconds so reloads and
  // route remounts do not churn IndexedDB/realtime ownership. Cross that real
  // boundary rather than introducing a test-only timeout into worker code.
  await new Promise((resolve) => setTimeout(resolve, 31_500))

  const fourth = await openPage()
  const fourthOwner = await fourth.evaluate<string>(
    `window.inlineCoreOwnerHarness.connect("fourth-tab")`,
  )
  if (fourthOwner === firstOwner) {
    throw new Error(
      "Inline account owner survived beyond its production idle teardown boundary",
    )
  }
  const fourthDraft = await fourth.evaluate<string | undefined>(
    `window.inlineCoreOwnerHarness.loadDraftText("fourth-tab")`,
  )
  if (fourthDraft !== draftText) {
    throw new Error(
      `Recreated owner did not selectively hydrate its durable draft: ${JSON.stringify(fourthDraft)}`,
    )
  }
  await fourth.evaluate(
    `window.inlineCoreOwnerHarness.clearDraft("fourth-tab")`,
  )
  const clearedDraft = await fourth.evaluate<string | undefined>(
    `window.inlineCoreOwnerHarness.loadDraftText("fourth-tab")`,
  )
  if (clearedDraft !== undefined) {
    throw new Error(
      `Cleared draft remained projected: ${JSON.stringify(clearedDraft)}`,
    )
  }

  const errors = await Promise.all(
    pages.map((page) =>
      page.evaluate<string[]>(
        `window.inlineCoreOwnerHarness.errors()`,
      ),
    ),
  )
  const runtimeErrors = errors.flat()
  if (runtimeErrors.length > 0) {
    throw new Error(
      `Inline core owner browser errors: ${JSON.stringify(runtimeErrors)}`,
    )
  }
  await fourth.evaluate(
    `window.inlineCoreOwnerHarness.detach("fourth-tab")`,
  )

  console.log(
    JSON.stringify(
      {
        firstOwner,
        secondOwner,
        thirdOwner,
        fourthOwner,
        crossVersionResult,
        firstPhase,
        secondPhase,
        revision,
        revisionAfterPeerDetach,
        draftTextAcrossRenderers: secondDraft,
        draftTextAfterWarmAttach: thirdDraft,
        draftTextAfterOwnerRecreation: fourthDraft,
        clearedDraft: clearedDraft ?? null,
        runtimeErrors,
      },
      null,
      2,
    ),
  )
} finally {
  await Promise.all(pages.map((page) => page.close()))
}
