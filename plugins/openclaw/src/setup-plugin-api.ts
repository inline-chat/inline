// Setup entry for package onboarding. Keep this pointed at the narrow setup
// plugin so setup-only paths do not load tools, gateway hooks, or monitors.
export { inlineSetupPlugin } from "./inline/setup-plugin.js"
