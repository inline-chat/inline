/**
 * Lab only: media made in the page, so nothing is fetched from the network.
 * Pictures are drawn to a canvas and encoded to blobs; stripped previews go
 * through the lab's encoder; voice notes are generated WAV; GIFs are a canvas
 * animation recorded to WebM where the browser can.
 */

import { encodeStripped } from "./stripped-encoder"

export type Picture = {
  readonly width: number
  readonly height: number
  readonly hue: number
  readonly label: string
  /** Transparent background, a round face (stickers, PNG photos). */
  readonly transparent?: boolean
}

const canvasOf = (width: number, height: number): HTMLCanvasElement => {
  const canvas = document.createElement("canvas")
  canvas.width = Math.max(1, Math.round(width))
  canvas.height = Math.max(1, Math.round(height))
  return canvas
}

const draw = (context: CanvasRenderingContext2D, picture: Picture, width: number, height: number, phase = 0) => {
  context.clearRect(0, 0, width, height)
  if (picture.transparent) {
    const r = Math.min(width, height) * 0.45
    context.fillStyle = `hsl(${picture.hue} 85% 60%)`
    context.beginPath()
    context.arc(width / 2, height / 2, r, 0, Math.PI * 2)
    context.fill()
    context.fillStyle = "rgb(0 0 0 / 0.75)"
    context.beginPath()
    context.arc(width / 2 - r * 0.35, height / 2 - r * 0.2, r * 0.1, 0, Math.PI * 2)
    context.arc(width / 2 + r * 0.35, height / 2 - r * 0.2, r * 0.1, 0, Math.PI * 2)
    context.fill()
    context.lineWidth = Math.max(1, r * 0.08)
    context.strokeStyle = "rgb(0 0 0 / 0.75)"
    context.beginPath()
    context.arc(width / 2, height / 2 + r * 0.05, r * 0.45, 0.15 * Math.PI, 0.85 * Math.PI)
    context.stroke()
    return
  }
  const gradient = context.createLinearGradient(0, 0, width, height)
  gradient.addColorStop(0, `hsl(${picture.hue} 70% 55%)`)
  gradient.addColorStop(1, `hsl(${(picture.hue + 60) % 360} 70% 35%)`)
  context.fillStyle = gradient
  context.fillRect(0, 0, width, height)
  const unit = Math.min(width, height)
  for (let index = 0; index < 5; index += 1) {
    const angle = phase + index * 1.3
    context.fillStyle = `hsl(${(picture.hue + index * 40) % 360} 80% 70% / 0.55)`
    context.beginPath()
    context.arc(
      width * (0.2 + 0.15 * index) + Math.cos(angle) * unit * 0.05,
      height * (0.3 + 0.1 * ((index * 7) % 5)) + Math.sin(angle) * unit * 0.05,
      unit * (0.08 + 0.03 * index),
      0,
      Math.PI * 2,
    )
    context.fill()
  }
  if (width >= 120) {
    context.fillStyle = "rgb(255 255 255 / 0.92)"
    context.font = `600 ${Math.round(unit / 9)}px system-ui, sans-serif`
    context.textAlign = "center"
    context.textBaseline = "middle"
    context.fillText(picture.label, width / 2, height / 2)
  }
}

const scaleTo = (picture: Picture, maxSide: number) => {
  const scale = Math.min(1, maxSide / Math.max(picture.width, picture.height))
  return { width: Math.max(1, Math.round(picture.width * scale)), height: Math.max(1, Math.round(picture.height * scale)) }
}

/** The picture as an encoded image blob, at most `maxSide` on its longest side. */
export const pictureBlob = (picture: Picture, maxSide = 1200): Promise<Blob> => {
  const size = scaleTo(picture, maxSide)
  const canvas = canvasOf(size.width, size.height)
  const context = canvas.getContext("2d")
  if (!context) return Promise.reject(new Error("no 2d context"))
  draw(context, picture, size.width, size.height)
  const type = picture.transparent ? "image/png" : "image/jpeg"
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        // Engines differ in what they return for a type they do not encode.
        if (!blob || blob.size === 0) reject(new Error("canvas returned no image"))
        else if (!blob.type.startsWith("image/")) reject(new Error(`canvas returned ${blob.type}`))
        else resolve(blob)
      },
      type,
      0.86,
    )
  })
}

/** Stripped thumbnail bytes for the picture (at most 40 px), or undefined for transparent ones. */
export const pictureStripped = (picture: Picture): Uint8Array | undefined => {
  if (picture.transparent) return undefined
  const size = scaleTo(picture, 40)
  const canvas = canvasOf(size.width, size.height)
  const context = canvas.getContext("2d")
  if (!context) return undefined
  draw(context, picture, size.width, size.height)
  const pixels = context.getImageData(0, 0, size.width, size.height).data
  return encodeStripped(pixels, size.width, size.height)
}

/** A short WAV tone with a little rhythm, for voice notes. */
export const voiceBlob = (seconds: number, frequency = 220): Blob => {
  const rate = 8000
  const samples = Math.max(1, Math.round(seconds * rate))
  const buffer = new ArrayBuffer(44 + samples * 2)
  const view = new DataView(buffer)
  const ascii = (offset: number, text: string) => {
    for (let index = 0; index < text.length; index += 1) view.setUint8(offset + index, text.charCodeAt(index))
  }
  ascii(0, "RIFF")
  view.setUint32(4, 36 + samples * 2, true)
  ascii(8, "WAVE")
  ascii(12, "fmt ")
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, rate, true)
  view.setUint32(28, rate * 2, true)
  view.setUint16(32, 2, true)
  view.setUint16(34, 16, true)
  ascii(36, "data")
  view.setUint32(40, samples * 2, true)
  for (let index = 0; index < samples; index += 1) {
    const time = index / rate
    const envelope = 0.5 + 0.5 * Math.sin(time * Math.PI * 3)
    view.setInt16(44 + index * 2, Math.round(Math.sin(2 * Math.PI * frequency * time) * envelope * 6000), true)
  }
  return new Blob([buffer], { type: "audio/wav" })
}

/** A second of the picture animating, recorded to WebM. Undefined where recording is unavailable. */
export const animationBlob = async (picture: Picture, seconds = 1.2): Promise<Blob | undefined> => {
  if (typeof MediaRecorder === "undefined") return undefined
  const size = scaleTo(picture, 320)
  const canvas = canvasOf(size.width, size.height)
  const context = canvas.getContext("2d")
  if (!context || typeof canvas.captureStream !== "function") return undefined
  const type = ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm", "video/mp4"].find((candidate) =>
    MediaRecorder.isTypeSupported(candidate),
  )
  if (!type) return undefined
  const stream = canvas.captureStream(24)
  const recorder = new MediaRecorder(stream, { mimeType: type })
  const chunks: Blob[] = []
  recorder.ondataavailable = (event) => {
    if (event.data.size > 0) chunks.push(event.data)
  }
  const done = new Promise<void>((resolve) => {
    recorder.onstop = () => resolve()
  })
  const start = performance.now()
  recorder.start()
  await new Promise<void>((resolve) => {
    const frame = () => {
      const elapsed = (performance.now() - start) / 1000
      draw(context, picture, size.width, size.height, elapsed * 4)
      if (elapsed < seconds) requestAnimationFrame(frame)
      else resolve()
    }
    requestAnimationFrame(frame)
  })
  recorder.stop()
  await done
  for (const track of stream.getTracks()) track.stop()
  return chunks.length > 0 ? new Blob(chunks, { type: type.split(";")[0] }) : undefined
}
