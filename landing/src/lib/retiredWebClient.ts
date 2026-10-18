// The retired web client ran at inline.chat/app and kept auth and a message
// cache on this origin. The web app now lives on its own origin, so remove
// whatever it left behind. The rest of the site stores nothing here except
// cookies, which this does not touch.

const INDEXED_DB_NAMES = ["inline-auth-session", "inline-client-db"]
const INDEXED_DB_PREFIX = "inline-client-db:"
const LOCAL_STORAGE_KEYS = [
  "auth-store",
  "auth-store:token",
  "auth-store:user-id",
  "auth-store:logout-pending",
  "inline-device-id",
]
const OPFS_ENTRIES = [".inline-sqlite-v1"]

export function retiredWebClientRedirect(): Response {
  return new Response(null, {
    status: 302,
    headers: {
      location: "/",
      "cache-control": "no-store",
      "clear-site-data": "\"storage\"",
    },
  })
}

export async function clearRetiredWebClientStorage(): Promise<void> {
  try {
    for (const key of LOCAL_STORAGE_KEYS) window.localStorage.removeItem(key)
  } catch {
    // Storage disabled.
  }

  if (typeof indexedDB !== "undefined") {
    const names = new Set(INDEXED_DB_NAMES)
    try {
      for (const database of await indexedDB.databases()) {
        if (database.name?.startsWith(INDEXED_DB_PREFIX)) names.add(database.name)
      }
    } catch {
      // databases() is unavailable in some browsers; fixed names still go.
    }
    for (const name of names) indexedDB.deleteDatabase(name)
  }

  try {
    const root = await navigator.storage.getDirectory()
    for (const entry of OPFS_ENTRIES) {
      await root.removeEntry(entry, { recursive: true }).catch(() => undefined)
    }
  } catch {
    // OPFS unavailable.
  }
}
