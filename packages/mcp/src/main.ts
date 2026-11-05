import { installMcpProcessDiagnostics } from "./server/process-diagnostics"

const diagnostics = installMcpProcessDiagnostics()
try {
  // Observe initialization failures before importing the application graph.
  const [{ createApp }, { defaultConfig }] = await Promise.all([import("./server/app"), import("./server/config")])
  const port = Number(process.env.PORT ?? "8791")
  const app = createApp(defaultConfig())

  Bun.serve({ port, fetch: app.fetch })
  diagnostics.started()
} catch (error) {
  diagnostics.startupFailure(error)
  throw error
}
