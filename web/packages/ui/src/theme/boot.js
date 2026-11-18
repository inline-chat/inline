// Inline appearance boot. A classic, synchronous script loaded from <head>
// before any stylesheet or module, so the first paint has the chosen
// appearance and window color. It must stay tiny, dependency-free and
// import-free: it is served as is (see src/theme/README.md, "Before first
// paint"). It reads the record AppearanceController writes under
// "inline.appearance.boot" and sets color-scheme and background-color on
// <html> through the CSSOM, which the content policy allows. The controller
// removes both when it applies its classes.
;(function () {
  try {
    var root = document.documentElement
    var raw = window.localStorage.getItem("inline.appearance.boot")
    if (!raw) return
    var record = JSON.parse(raw)
    if (!record || record.v !== 1) return
    var dark =
      record.a === "dark" ||
      (record.a === "system" &&
        typeof window.matchMedia === "function" &&
        window.matchMedia("(prefers-color-scheme: dark)").matches)
    if (record.a !== "dark" && record.a !== "light" && record.a !== "system") return
    var color = dark ? record.d : record.l
    root.style.setProperty("color-scheme", dark ? "dark" : "light")
    if (typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color)) root.style.setProperty("background-color", color)
    root.setAttribute("data-appearance-boot", dark ? "dark" : "light")
  } catch {
    // No storage, bad JSON: the page follows the system until the app applies.
  }
})()
