import { startDocumentAppearance } from "@inline/ui/theme/stylex"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import "./app/global.css"
import { App } from "./app/App"
import { boot } from "./app/boot"
import { createBootMetrics } from "./app/perf"

// First: the appearance on <html> (the pre-paint script set the canvas; this
// applies the classes and removes its stand-ins), then the boot mark.
const appearance = startDocumentAppearance()
const metrics = createBootMetrics({ performance: globalThis.performance })
metrics.mark("bootStart")

if (import.meta.env.DEV) {
  void import("virtual:stylex:runtime")
}

const root = document.getElementById("root")
if (!root) throw new Error("Missing #root")

const services = await boot({ appearance, metrics })
createRoot(root).render(
  <StrictMode>
    <App services={services} />
  </StrictMode>,
)
