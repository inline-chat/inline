import { landingPathForLocale, locales, type Locale } from "./preferences"

const productionOrigin = "https://inline.chat"

export function landingHead(locale: Locale) {
  return {
    meta: [
      {
        title: "Inline — The interface for multiplayer work",
      },
      {
        name: "description",
        content: "A work chat app redesigned from scratch around threads for people and agents.",
      },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "Inline — The interface for multiplayer work" },
      {
        name: "twitter:description",
        content: "A work chat app redesigned from scratch around threads for people and agents.",
      },
      { name: "twitter:image", content: `${productionOrigin}/twitter-og.jpg` },
      { name: "og:image", content: `${productionOrigin}/twitter-og.jpg` },
    ],
    links: [
      { rel: "canonical", href: `${productionOrigin}${landingPathForLocale(locale)}` },
      ...locales.map((alternate) => ({
        rel: "alternate",
        hrefLang: alternate.hrefLang,
        href: `${productionOrigin}${landingPathForLocale(alternate.code)}`,
      })),
      { rel: "alternate", hrefLang: "x-default", href: `${productionOrigin}/beta` },
    ],
  }
}
