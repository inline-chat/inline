import { ipcMain, type IpcMainInvokeEvent } from "electron"
import {
  DesktopIpc,
  type InlineDesktopAuthSession,
} from "../platform/DesktopApi"
import { INLINE_APP_ORIGIN } from "./AppProtocol"
import { InlineSessionVault } from "./InlineSessionVault"

const isTrustedSender = (event: IpcMainInvokeEvent, devOrigin?: string) => {
  try {
    const senderUrl = event.senderFrame?.url
    if (!senderUrl) return false
    const origin = new URL(senderUrl).origin
    return origin === INLINE_APP_ORIGIN || (devOrigin != null && origin === devOrigin)
  } catch {
    return false
  }
}

const assertTrustedSender = (event: IpcMainInvokeEvent, devOrigin?: string) => {
  if (!isTrustedSender(event, devOrigin)) {
    throw new Error("Untrusted Inline desktop IPC sender")
  }
}

export const registerAuthIpc = (devOrigin?: string) => {
  const vault = new InlineSessionVault()

  ipcMain.handle(DesktopIpc.loadSession, async (event) => {
    assertTrustedSender(event, devOrigin)
    return await vault.load()
  })

  ipcMain.handle(
    DesktopIpc.saveSession,
    async (event, session: InlineDesktopAuthSession) => {
      assertTrustedSender(event, devOrigin)
      return await vault.save(session)
    },
  )

  ipcMain.handle(DesktopIpc.clearSession, async (event) => {
    assertTrustedSender(event, devOrigin)
    await vault.clear()
  })
}
