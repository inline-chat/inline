export function Logo() {
  return <img className="inline-logo" src="/favicon.svg" alt="Inline" />
}

export function Boot({ text }: { text: string }) {
  return (
    <main className="boot">
      <Logo />
      <p>{text}</p>
    </main>
  )
}
