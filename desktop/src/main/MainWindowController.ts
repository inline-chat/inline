import { app, BrowserWindow, nativeTheme } from "electron"
import path from "node:path"
import { INLINE_APP_ORIGIN } from "./AppProtocol"
import { restrictExternalNavigation } from "./ExternalNavigation"

let mainWindow: BrowserWindow | null = null

export const showMainWindow = (): BrowserWindow => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.show()
    mainWindow.focus()
    return mainWindow
  }

  const devUrl = !app.isPackaged ? process.env.INLINE_WEB_DEV_URL : undefined
  const devOrigin = devUrl ? new URL(devUrl).origin : undefined
  const window = new BrowserWindow({
    title: "Inline",
    width: 860,
    height: 640,
    minWidth: 500,
    minHeight: 300,
    show: false,
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#242426" : "#f6f6f6",
    ...(process.platform === "darwin"
      ? {
          titleBarStyle: "hiddenInset" as const,
        }
      : {}),
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      devTools: !app.isPackaged,
      spellcheck: true,
    },
  })

  mainWindow = window
  restrictExternalNavigation(window, devOrigin)
  window.once("ready-to-show", () => window.show())
  window.on("closed", () => {
    if (mainWindow === window) mainWindow = null
  })

  void window.loadURL(devUrl ?? `${INLINE_APP_ORIGIN}/`)
  return window
}
