import { describe, it, expect } from "bun:test"
import {
  generateNotionPropertiesSchema,
  findTitleProperty,
  extractTaskTitle,
  getPropertyDescriptions,
} from "../schemaGenerator"

describe("Notion Schema Generator", () => {
  const mockDatabase = {
    properties: {
      Name: {
        type: "title",
      },
      Description: {
        type: "rich_text",
      },
      "Food group": {
        type: "select",
      },
      Tags: {
        type: "multi_select",
      },
      Assignee: {
        type: "people",
      },
      "Due Date": {
        type: "date",
      },
      Completed: {
        type: "checkbox",
      },
      Priority: {
        type: "number",
      },
      Status: {
        type: "status",
      },
    },
  }

  it("should generate a valid Zod schema from database properties", () => {
    const schema = generateNotionPropertiesSchema(mockDatabase)
    expect(schema).toBeDefined()

    // Test that the schema can parse valid data
    const validData = {
      Name: {
        title: [{ text: { content: "Test Task" } }],
      },
      Description: {
        rich_text: [{ text: { content: "Test description" } }],
      },
      "Food group": {
        select: { name: "Vegetable" },
      },
      Tags: {
        multi_select: [{ name: "urgent" }, { name: "important" }],
      },
      Assignee: {
        people: [{ id: "user123" }],
      },
      "Due Date": {
        date: { start: "2024-01-15" },
      },
      Completed: {
        checkbox: false,
      },
      Priority: {
        number: 1,
      },
      Status: {
        status: { name: "In Progress" },
      },
    }

    expect(() => schema.parse(validData)).not.toThrow()
  })

  it("should find the title property correctly", () => {
    const titleProperty = findTitleProperty(mockDatabase)
    expect(titleProperty).toBe("Name")
  })

  it("should extract task title from properties data", () => {
    const propertiesData = {
      Name: {
        title: [{ text: { content: "My Task Title" } }],
      },
    }

    const title = extractTaskTitle(propertiesData, "Name")
    expect(title).toBe("My Task Title")
  })

  it("should return null when title property doesn't exist", () => {
    const propertiesData = {
      Description: {
        rich_text: [{ text: { content: "Some description" } }],
      },
    }

    const title = extractTaskTitle(propertiesData, "Name")
    expect(title).toBeNull()
  })

  it("should generate property descriptions", () => {
    const descriptions = getPropertyDescriptions(mockDatabase)
    expect(descriptions).toContain('"Name" (title)')
    expect(descriptions).toContain('"Description" (rich_text)')
    expect(descriptions).toContain('"Food group" (select)')
  })

  it("should handle databases with no properties", () => {
    const emptyDatabase = { properties: {} }
    const schema = generateNotionPropertiesSchema(emptyDatabase)
    expect(schema).toBeDefined()

    // Should parse empty object
    expect(() => schema.parse({})).not.toThrow()
  })

  it("should handle unknown property types gracefully", () => {
    const databaseWithUnknownType = {
      properties: {
        Unknown: {
          type: "unknown_type",
        },
      },
    }

    const schema = generateNotionPropertiesSchema(databaseWithUnknownType)
    expect(schema).toBeDefined()

    // Should accept any value for unknown types
    expect(() => schema.parse({ Unknown: "any value" })).not.toThrow()
  })
})
