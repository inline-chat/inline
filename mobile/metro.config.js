const path = require("path")
const { getSentryExpoConfig } = require("@sentry/react-native/metro")

const projectRoot = __dirname
const workspaceRoot = path.resolve(projectRoot, "..")

const config = getSentryExpoConfig(projectRoot, {
  annotateReactComponents: true,
})

config.watchFolders = [workspaceRoot]
config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, "node_modules"),
  path.resolve(workspaceRoot, "node_modules"),
]

module.exports = config
