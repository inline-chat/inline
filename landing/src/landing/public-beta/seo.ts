import { landingPathForLocale, locales, type Locale } from "./preferences"

const productionOrigin = "https://inline.chat"

export function landingHead(locale: Locale) {
  return {
    meta: [
      {
        title: "Inline - A fast, lightweight and powerful work chat app",
      },
      {
        name: "description",
        content: "A fast, lightweight and powerful chat app for teams that makes sharing ideas an absolute joy.",
      },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "Inline - Work chat 2.0" },
      {
        name: "twitter:description",
        content:
          "Inline is a fast, lightweight, scalable, and powerful work chat app designed to spark new ideas, enable maximum sharing, while allowing longest possible focus time.",
      },
      { name: "twitter:image", content: `${productionOrigin}/twitter-og.jpg` },
      { name: "og:image", content: `${productionOrigin}/twitter-og.jpg` },
    ],
    links: [
      { rel: "canonical", href: `${productionOrigin}${landingPathForLocale(locale)}` },
      ...locales.map((alternate) => ({
        rel: "alternate",
        hreflang: alternate.hrefLang,
        href: `${productionOrigin}${landingPathForLocale(alternate.code)}`,
      })),
      { rel: "alternate", hreflang: "x-default", href: `${productionOrigin}/beta` },
    ],
  }
}
