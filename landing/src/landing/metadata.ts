import { LANDING_COPY } from "./content"

const title = `Inline: ${LANDING_COPY.headline}`
const description = LANDING_COPY.summaryLines.join(" ")
const url = "https://inline.chat/"
const image = "https://inline.chat/twitter-og.jpg"

export const LANDING_METADATA = {
  title,
  description,
  url,
  siteName: "Inline",
  twitter: {
    card: "summary_large_image",
    title,
    description,
    image,
  },
  openGraph: {
    title,
    description,
    image,
  },
  website: {
    "@context": "https://schema.org",
    "@type": "WebSite",
    name: "Inline",
    alternateName: "Inline Chat",
    url,
  },
} as const
