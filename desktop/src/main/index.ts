import { app, session } from "electron"
import path from "node:path"
import { registerInlineAppProtocol, registerInlineAppScheme } from "./AppProtocol"
import { registerAuthIpc } from "./AuthIpc"
import { showMainWindow } from "./MainWindowController"

registerInlineAppScheme()
app.enableSandbox()
app.setName("Inline")
if (!app.isPackaged) {
  app.setPath("userData", path.join(app.getPath("appData"), "Inline Web Dev"))
}

const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) {
  app.quit()
} else {
  app.on("second-instance", () => {
    showMainWindow()
  })

  app.whenReady().then(() => {
    const devUrl = !app.isPackaged ? process.env.INLINE_WEB_DEV_URL : undefined
    const devOrigin = devUrl ? new URL(devUrl).origin : undefined

    if (app.isPackaged) {
      registerInlineAppProtocol(path.join(app.getAppPath(), "dist", "client"))
    }

    registerAuthIpc(devOrigin)
    session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
      callback(false)
    })
    showMainWindow()

    app.on("activate", () => {
      showMainWindow()
    })
  })

  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit()
  })
}
