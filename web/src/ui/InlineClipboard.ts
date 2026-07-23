export const writeInlineClipboardText = async (text: string) => {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text)
    return
  }

  const input = document.createElement("textarea")
  input.value = text
  input.setAttribute("readonly", "")
  input.style.position = "fixed"
  input.style.opacity = "0"
  document.body.append(input)
  input.select()
  const copied = document.execCommand("copy")
  input.remove()
  if (!copied) throw new Error("The browser denied clipboard access.")
}
