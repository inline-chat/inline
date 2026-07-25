import { contextBridge, ipcRenderer } from "electron"
import {
  DesktopIpc,
  type InlineDesktopApi,
  type InlineDesktopAuthSession,
  type InlineDesktopPlatform,
} from "../platform/DesktopApi"

const platform = process.platform as InlineDesktopPlatform

const api: InlineDesktopApi = Object.freeze({
  platform,
  auth: Object.freeze({
    loadSession: () => ipcRenderer.invoke(DesktopIpc.loadSession),
    saveSession: (session: InlineDesktopAuthSession) =>
      ipcRenderer.invoke(DesktopIpc.saveSession, {
        token: session.token,
        userId: session.userId,
      }),
    clearSession: () => ipcRenderer.invoke(DesktopIpc.clearSession),
  }),
})

contextBridge.exposeInMainWorld("inlineDesktop", api)

window.addEventListener("DOMContentLoaded", () => {
  document.documentElement.dataset.inlineDesktop = platform
})
