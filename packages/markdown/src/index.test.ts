import { describe, expect, test } from "bun:test"
import { normalizeMarkdownText, parseMarkdownOutput } from "./index"

describe("parseMarkdownOutput", () => {
  test("extracts markdown image embeds and removes them from display text", () => {
    expect(
      parseMarkdownOutput(
        "Here's a cockatiel for you\n\n![Cockatiel](https://upload.wikimedia.org/image.jpg)",
      ),
    ).toEqual({
      text: "Here's a cockatiel for you",
      images: [
        {
          type: "image",
          alt: "Cockatiel",
          url: "https://upload.wikimedia.org/image.jpg",
          title: undefined,
        },
      ],
    })
  })

  test("keeps image markdown inside fenced code blocks", () => {
    expect(parseMarkdownOutput("```md\n![x](https://example.com/x.png)\n```")).toEqual({
      text: "```md\n![x](https://example.com/x.png)\n```",
      images: [],
    })
  })

  test("supports quoted titles and angle wrapped urls", () => {
    expect(parseMarkdownOutput('![Alt](<https://example.com/a.png> "Title")')).toEqual({
      text: "",
      images: [
        {
          type: "image",
          alt: "Alt",
          url: "https://example.com/a.png",
          title: "Title",
        },
      ],
    })
  })

  test("extracts markdown image urls containing parentheses", () => {
    const url = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Cockatiel_(Nymphicus_hollandicus).jpg/800px-Cockatiel_(Nymphicus_hollandicus).jpg"

    expect(parseMarkdownOutput(`![Cockatiel](${url})`)).toEqual({
      text: "",
      images: [
        {
          type: "image",
          alt: "Cockatiel",
          url,
          title: undefined,
        },
      ],
    })
  })

  test("leaves extra images in text when maxImages is reached", () => {
    expect(parseMarkdownOutput("![one](https://a.test/1.png)\n![two](https://a.test/2.png)", { maxImages: 1 })).toEqual({
      text: "![two](https://a.test/2.png)",
      images: [
        {
          type: "image",
          alt: "one",
          url: "https://a.test/1.png",
          title: undefined,
        },
      ],
    })
  })

  test("leaves image markdown in text when protocol is not allowed", () => {
    expect(parseMarkdownOutput("![x](http://example.com/x.png)", { allowedImageProtocols: ["https:"] })).toEqual({
      text: "![x](http://example.com/x.png)",
      images: [],
    })
  })

  test("normalizes hard-wrapped markdown links outside code blocks", () => {
    const input = [
      "Here are 3 more cockatiel image sources:",
      "",
      "- [Cockatiel photos on Pixabay](https://pixabay.com/images/search/cockatiel/)",
      "-",
      "  [Cockatiel photos on Flickr](https://www.flickr.com/search/?text=cockatiel)",
      "- [Cockatiel images on Adobe Stock](https://stock.adobe.com/",
      "  search?k=cockatiel)",
    ].join("\n")

    expect(parseMarkdownOutput(input)).toEqual({
      text: [
        "Here are 3 more cockatiel image sources:",
        "",
        "- [Cockatiel photos on Pixabay](https://pixabay.com/images/search/cockatiel/)",
        "- [Cockatiel photos on Flickr](https://www.flickr.com/search/?text=cockatiel)",
        "- [Cockatiel images on Adobe Stock](https://stock.adobe.com/search?k=cockatiel)",
      ].join("\n"),
      images: [],
    })
  })

  test("extracts hard-wrapped markdown image embeds", () => {
    expect(
      parseMarkdownOutput([
        "Here is one:",
        "",
        "-",
        "  ![Cockatiel](https://upload.wikimedia.org/",
        "  image.jpg)",
      ].join("\n")),
    ).toEqual({
      text: "Here is one:",
      images: [
        {
          type: "image",
          alt: "Cockatiel",
          url: "https://upload.wikimedia.org/image.jpg",
          title: undefined,
        },
      ],
    })
  })

  test("preserves hard-wrapped markdown inside fenced code blocks", () => {
    const input = [
      "```md",
      "-",
      "  [Cockatiel](https://example.com/",
      "  bird)",
      "```",
    ].join("\n")

    expect(normalizeMarkdownText(input)).toBe(input)
    expect(parseMarkdownOutput(input)).toEqual({
      text: input,
      images: [],
    })
  })
})
