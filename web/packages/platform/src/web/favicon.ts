/**
 * The favicon badge: the app icon with a red count in the corner, drawn on a
 * canvas and set as a `data:` URL (allowed by `img-src`). Isolated here so a
 * context without a 2D canvas skips the favicon and keeps the title prefix.
 */

export interface FaviconRenderer {
  /** A data URL of the base icon with `label` on it, or null if drawing failed. */
  render(baseHref: string, label: string): Promise<string | null>
}

type Context2D = {
  clearRect(x: number, y: number, w: number, h: number): void
  drawImage(image: unknown, x: number, y: number, w: number, h: number): void
  beginPath(): void
  arc(x: number, y: number, r: number, start: number, end: number): void
  fill(): void
  fillText(text: string, x: number, y: number): void
  fillStyle: string
  font: string
  textAlign: string
  textBaseline: string
}

type CanvasLike = {
  width: number
  height: number
  getContext(kind: "2d"): Context2D | null
  toDataURL(type: string): string
}

type ImageLike = {
  src: string
  decoding?: string
  onload: (() => void) | null
  onerror: (() => void) | null
}

const SIZE = 32
const BADGE_COLOR = "#e5484d"

/** A canvas renderer, or null where the document cannot make a 2D canvas. */
export const canvasFaviconRenderer = (document: {
  createElement(tagName: string): unknown
}): FaviconRenderer | null => {
  let canvas: CanvasLike
  let context: Context2D | null
  try {
    canvas = document.createElement("canvas") as CanvasLike
    context = typeof canvas.getContext === "function" ? canvas.getContext("2d") : null
  } catch {
    return null
  }
  if (!context) return null
  const ctx = context
  canvas.width = SIZE
  canvas.height = SIZE

  const loadImage = (href: string): Promise<ImageLike | null> =>
    new Promise((resolve) => {
      const image = document.createElement("img") as ImageLike
      image.onload = () => resolve(image)
      image.onerror = () => resolve(null)
      image.src = href
    })

  return {
    async render(baseHref, label) {
      try {
        const image = await loadImage(baseHref)
        ctx.clearRect(0, 0, SIZE, SIZE)
        if (image) ctx.drawImage(image, 0, 0, SIZE, SIZE)
        const radius = label.length > 2 ? 11 : 9
        const cx = SIZE - radius
        const cy = radius
        ctx.fillStyle = BADGE_COLOR
        ctx.beginPath()
        ctx.arc(cx, cy, radius, 0, Math.PI * 2)
        ctx.fill()
        ctx.fillStyle = "#ffffff"
        ctx.font = `bold ${label.length > 2 ? 10 : 13}px system-ui, sans-serif`
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.fillText(label, cx, cy + 1)
        return canvas.toDataURL("image/png")
      } catch {
        return null
      }
    },
  }
}
