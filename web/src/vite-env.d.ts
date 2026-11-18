/// <reference types="vite/client" />

declare module "virtual:stylex:runtime"

/** Injected by vite.config.ts. Sorts lexically, newest last. */
declare const __INLINE_BUILD_ID__: string

/**
 * True only in the labs build (tooling/vite.labs.config.ts); `false` in the
 * production config. With `import.meta.env.DEV`, it decides whether the demo
 * and `__inlineApp` are compiled in.
 */
declare const __INLINE_DEMO__: boolean
