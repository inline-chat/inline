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
})

describe("mapNotionSearchResponse", () => {
  test("maps full pages and data sources without fetching partial hits", () => {
    const response = {
      results: [
        {
          object: "page",
          id: "page-1",
          url: "https://www.notion.so/page-1",
          icon: { type: "emoji", emoji: "🧭" },
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
      },
      {
        id: "database-1",
        provider: "notion",
        kind: "database",
        title: "Projects",
        url: "https://www.notion.so/database-1",
        subtitle: "Notion database",
        emoji: undefined,
      },
    ])
  })
})
