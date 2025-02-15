export const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))
export const debugDelay = (ms: number) => {
  if (process.env.NODE_ENV === "development") {
    return new Promise((resolve) => setTimeout(resolve, ms))
  } else {
    return Promise.resolve()
  }
}
