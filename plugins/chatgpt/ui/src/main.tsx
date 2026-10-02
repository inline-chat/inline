import { createRoot } from "react-dom/client"
import { App } from "./App"
import { HostBridge } from "./bridge"

const bridge = new HostBridge()
const root = createRoot(document.getElementById("root")!)
root.render(<App bridge={bridge} />)
bridge.subscribe((event) => { if (event.kind === "state" && event.state.status === "closed") root.unmount() })
window.addEventListener("pagehide", () => bridge.dispose(), { once: true })
