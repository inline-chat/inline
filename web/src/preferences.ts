export function readPreference(key: string, fallback: string): string {
  try {
    return localStorage.getItem(key) ?? fallback
  } catch {
    return fallback
  }
}

export function applyTheme(theme: string): void {
  document.documentElement.dataset.theme = theme === "light" || theme === "dark" ? theme : "system"
}
