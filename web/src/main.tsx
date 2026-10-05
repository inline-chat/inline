import { createRoot } from "react-dom/client"
import { applyTheme, readPreference } from "./preferences"
import "./style.css"

const root = createRoot(document.getElementById("root")!)
if (__INLINE_WEB_ENABLED__) {
  applyTheme(readPreference("inline-web-theme", "system"))
  root.render(
    <main className="boot">
      <img src="/favicon.svg" alt="Inline" />
      <p>Opening Inline…</p>
    </main>
  )
  void import("./App").then(
    ({ App }) => root.render(<App />),
    () => {
      root.render(
        <main className="boot">
          <h1>Couldn’t load Inline</h1>
          <p>Your saved session and messages are preserved.</p>
          <button onClick={() => location.reload()}>Reload</button>
        </main>
      )
    }
  )
} else {
  root.render(
    <main className="boot">
      <img src="/favicon.svg" alt="Inline" />
      <h1>Inline web is in development</h1>
      <p>This build has the experimental client disabled.</p>
      <a href="https://inline.chat/download">Get Inline</a>
    </main>
  )
}
