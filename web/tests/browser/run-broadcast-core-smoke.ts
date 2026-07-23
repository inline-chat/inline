import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const pages: ChromeDevtoolsPage[] = []
const harnessDocument = (
  await Bun.file(
    new URL("../fixtures/core-broadcast-harness.html", import.meta.url),
  ).text()
).replaceAll("__INLINE_APP_ORIGIN__", appOrigin)

const openPage = async () => {
  const page = await ChromeDevtoolsPage.open(debuggerOrigin)
  pages.push(page)
  await page.navigate(appOrigin)
  const harnessUrl = await page.evaluate<string>(`URL.createObjectURL(
    new Blob([${JSON.stringify(harnessDocument)}], { type: "text/html" })
  )`)
  await page.navigate(harnessUrl)
  await page.evaluate(`(async () => {
    const deadline = performance.now() + 5_000
    while (!window.inlineBroadcastCoreHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline broadcast core harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)
  return page
}

try {
  const owner = await openPage()
  await owner.evaluate(
    `window.inlineBroadcastCoreHarness.start("browser-owner")`,
  )
  const firstOwner = await owner.evaluate<string>(
    `window.inlineBroadcastCoreHarness.ping("owner-ping")`,
  )
  if (firstOwner !== "browser-owner") {
    throw new Error(`First tab did not own its core: ${firstOwner}`)
  }

  const follower = await openPage()
  await follower.evaluate(
    `window.inlineBroadcastCoreHarness.start("browser-follower")`,
  )
  const secondOwner = await follower.evaluate<string>(
    `window.inlineBroadcastCoreHarness.ping("follower-ping")`,
  )
  if (secondOwner !== firstOwner) {
    throw new Error(
      `Follower routed to a different owner: ${firstOwner} / ${secondOwner}`,
    )
  }

  const [ownerHosts, followerHosts] = await Promise.all([
    owner.evaluate<number>(
      `window.inlineBroadcastCoreHarness.hostCreations()`,
    ),
    follower.evaluate<number>(
      `window.inlineBroadcastCoreHarness.hostCreations()`,
    ),
  ])
  if (ownerHosts !== 1 || followerHosts !== 0) {
    throw new Error(
      `Expected one browser host, got owner=${ownerHosts} follower=${followerHosts}`,
    )
  }

  await owner.evaluate(
    `window.inlineBroadcastCoreHarness.shutdown()`,
  )
  await follower.evaluate(`(async () => {
    const deadline = performance.now() + 3_000
    while (window.inlineBroadcastCoreHarness.ownerErrors().length === 0) {
      if (performance.now() >= deadline) {
        throw new Error("Follower did not observe browser owner shutdown")
      }
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
  })()`)
  const followerErrors = await follower.evaluate<string[]>(
    `window.inlineBroadcastCoreHarness.ownerErrors()`,
  )
  if (!followerErrors.some((error) => error.includes("reload is required"))) {
    throw new Error(
      `Follower owner-loss error was not terminal: ${JSON.stringify(followerErrors)}`,
    )
  }
  await follower.evaluate(
    `window.inlineBroadcastCoreHarness.shutdown()`,
  )

  console.log(
    JSON.stringify(
      {
        firstOwner,
        secondOwner,
        ownerHosts,
        followerHosts,
        followerErrors,
      },
      null,
      2,
    ),
  )
} finally {
  await Promise.all(pages.map((page) => page.close()))
}
