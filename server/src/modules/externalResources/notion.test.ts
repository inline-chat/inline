import { describe, expect, test } from "bun:test"
import type { SearchResponse } from "@notionhq/client/build/src/api-endpoints"
import { mapNotionSearchResponse, notionSearchParameters } from "./notion"

describe("notionSearchParameters", () => {
  test("omits query for recent resources and keeps last-edited ordering", () => {
    expect(notionSearchParameters("", 6)).toEqual({
      sort: {
        direction: "descending",
        timestamp: "last_edited_time",
      },
      page_size: 6,
    })
  })

  test("includes a non-empty title query", () => {
    expect(notionSearchParameters("roadmap", 6)).toEqual({
      query: "roadmap",
      sort: {
        direction: "descending",
        timestamp: "last_edited_time",
      },
      page_size: 6,
    })
  })

  test("separates data sources from page rows before the result limit", () => {
    expect(notionSearchParameters("Reminders", 12, "data_source")).toMatchObject({
      query: "Reminders", page_size: 12, filter: { property: "object", value: "data_source" },
    })
    expect(notionSearchParameters("Reminders", 24, "page")).toMatchObject({
      page_size: 24, filter: { property: "object", value: "page" },
    })
  })
})

describe("mapNotionSearchResponse", () => {
  test("bounds cached titles while retaining complete page emoji", () => {
    const emoji = "👩🏽‍❤️‍💋‍👩🏻"
    const response = { results: [{
      object: "data_source", id: "source", url: "https://notion.so/source",
      icon: { type: "emoji", emoji }, title: [{ plain_text: "x".repeat(10_000) }],
    }] } as unknown as SearchResponse
    const result = mapNotionSearchResponse(response)[0]
    expect(result?.title).toHaveLength(4_096)
    expect(result?.emoji).toBe(emoji)
  })

  test("maps full pages and data sources without fetching partial hits", () => {
    const response = {
      results: [
        {
          object: "page",
          id: "page-1",
          url: "https://www.notion.so/page-1",
          icon: { type: "emoji", emoji: "🧭" },
          parent: { type: "data_source_id", data_source_id: "source-1" },
          last_edited_time: "2026-08-30T10:00:00Z",
          properties: {
            Name: {
              type: "title",
              title: [
                { plain_text: "Product\n" },
                { plain_text: " roadmap" },
              ],
            },
          },
        },
        {
          object: "data_source",
          id: "database-1",
          url: "https://www.notion.so/database-1",
          icon: null,
          title: [{ plain_text: "Projects" }],
        },
        { object: "page", id: "partial-page" },
      ],
    } as unknown as SearchResponse

    expect(mapNotionSearchResponse(response)).toEqual([
      {
        id: "page-1",
        provider: "notion",
        kind: "page",
        title: "Product roadmap",
        url: "https://www.notion.so/page-1",
        subtitle: "Notion page",
        emoji: "🧭",
        parentKind: "database",
        lastEditedTime: "2026-08-30T10:00:00Z",
      },
      {
        id: "database-1",
        provider: "notion",
        kind: "database",
        title: "Projects",
        url: "https://www.notion.so/database-1",
        subtitle: "Notion database",
        emoji: undefined,
        lastEditedTime: undefined,
      },
    ])
  })
})
