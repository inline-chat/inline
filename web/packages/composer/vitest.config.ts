import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
    environmentOptions: {
      // DOM tests parse hostile markup: nothing may load or navigate.
      happyDOM: {
        settings: {
          disableJavaScriptFileLoading: true,
          disableCSSFileLoading: true,
          handleDisabledFileLoadingAsSuccess: true,
          navigation: {
            disableMainFrameNavigation: true,
            disableChildFrameNavigation: true,
            disableChildPageNavigation: true,
            disableFallbackToSetURL: true,
          },
        },
      },
    },
  },
})
