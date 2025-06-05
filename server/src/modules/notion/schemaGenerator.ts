import { z } from "zod"
import { Log } from "@in/server/utils/log"

const log = new Log("NotionSchemaGenerator")

// Simplified schema with minimal nesting because OpenAI gets 5 levels of nested schema.
const richTextSchema = z.object({
  content: z.string(),
  url: z.string().nullable(),
})

const blockSchema = z.object({
  type: z.enum(["paragraph", "bulleted_list_item"]),
  rich_text: z.array(richTextSchema),
})

// Simplified icon schema
const iconSchema = z
  .object({
    type: z.enum(["emoji", "external", "file"]).nullable(),
    emoji: z.string().nullable(),
    url: z.string().nullable(),
  })
  .nullable()

/**
 * Generates a dynamic Zod schema based on Notion database properties
 * @param database - The Notion database object with properties
 * @returns A Zod schema that matches the database structure
 */
export function generateNotionPropertiesSchema(database: any): z.ZodType<any> {
  const properties = database.properties || {}
  const schemaFields: Record<string, z.ZodType<any>> = {}

  // Priority order for property types (most important first)
  const priorityTypes = [
    "title",
    "rich_text",
    "select",
    "multi_select",
    "people",
    "date",
    "checkbox",
    "status",
    "number",
    "url",
    "email",
    "phone_number",
  ]

  // Skip read-only and auto-managed properties, and complex types that cause issues
  const skipTypes = [
    "formula",
    "rollup",
    "created_time",
    "last_edited_time",
    "created_by",
    "last_edited_by",
    "relation", // Skip relation properties as they're complex and cause schema issues
    "files", // Skip files as they're complex
    "unique_id", // Skip unique_id as it's auto-managed
  ]

  // First, collect properties by priority
  const prioritizedProperties: Array<[string, any]> = []
  const otherProperties: Array<[string, any]> = []

  Object.entries(properties).forEach(([propertyName, propertyConfig]: [string, any]) => {
    const propertyType = propertyConfig.type

    if (skipTypes.includes(propertyType)) {
      return // Skip read-only properties and complex types
    }

    const priorityIndex = priorityTypes.indexOf(propertyType)
    if (priorityIndex !== -1) {
      prioritizedProperties.push([propertyName, propertyConfig])
    } else {
      otherProperties.push([propertyName, propertyConfig])
    }
  })

  // Sort prioritized properties by their priority order
  prioritizedProperties.sort(([, a], [, b]) => {
    const aIndex = priorityTypes.indexOf(a.type)
    const bIndex = priorityTypes.indexOf(b.type)
    return aIndex - bIndex
  })

  // Combine prioritized and other properties, but limit total count
  const allProperties = [...prioritizedProperties, ...otherProperties]

  // Limit to ~25 properties to stay well under the 100 parameter limit
  // (accounting for the nested structure which multiplies parameters)
  const maxProperties = 25
  const limitedProperties = allProperties.slice(0, maxProperties)

  if (allProperties.length > maxProperties) {
    log.warn(
      `Database has ${allProperties.length} properties, limiting to ${maxProperties} to stay under OpenAI's 100 parameter limit`,
    )
    log.info(
      "Included properties:",
      limitedProperties.map(([name, config]) => `${name} (${config.type})`),
    )
    log.info(
      "Excluded properties:",
      allProperties.slice(maxProperties).map(([name, config]) => `${name} (${config.type})`),
    )
  } else {
    log.info(`Including all ${allProperties.length} properties in schema`)
  }

  limitedProperties.forEach(([propertyName, propertyConfig]: [string, any]) => {
    const propertyType = propertyConfig.type

    switch (propertyType) {
      case "title":
        schemaFields[propertyName] = z
          .object({
            title: z.array(
              z.object({
                text: z.object({
                  content: z.string(),
                }),
              }),
            ),
          })
          .nullable()
        break

      case "rich_text":
        schemaFields[propertyName] = z
          .object({
            rich_text: z.array(
              z.object({
                text: z.object({
                  content: z.string(),
                }),
              }),
            ),
          })
          .nullable()
        break

      case "select":
        schemaFields[propertyName] = z
          .object({
            select: z
              .object({
                name: z.string(),
              })
              .nullable(),
          })
          .nullable()
        break

      case "multi_select":
        schemaFields[propertyName] = z
          .object({
            multi_select: z.array(
              z.object({
                name: z.string(),
              }),
            ),
          })
          .nullable()
        break

      case "people":
        schemaFields[propertyName] = z
          .object({
            people: z.array(
              z.object({
                id: z.string(),
              }),
            ),
          })
          .nullable()
        break

      case "date":
        schemaFields[propertyName] = z
          .object({
            date: z
              .object({
                start: z.string(), // YYYY-MM-DD format
                end: z.string().nullable(),
              })
              .nullable(),
          })
          .nullable()
        break

      case "checkbox":
        schemaFields[propertyName] = z
          .object({
            checkbox: z.boolean(),
          })
          .nullable()
        break

      case "number":
        schemaFields[propertyName] = z
          .object({
            number: z.number().nullable(),
          })
          .nullable()
        break

      case "url":
        schemaFields[propertyName] = z
          .object({
            url: z.string().nullable(),
          })
          .nullable()
        break

      case "email":
        schemaFields[propertyName] = z
          .object({
            email: z.string().nullable(),
          })
          .nullable()
        break

      case "phone_number":
        schemaFields[propertyName] = z
          .object({
            phone_number: z.string().nullable(),
          })
          .nullable()
        break

      case "status":
        schemaFields[propertyName] = z
          .object({
            status: z
              .object({
                name: z.string(),
              })
              .nullable(),
          })
          .nullable()
        break

      default:
        // For unknown property types, skip them entirely to avoid schema issues
        log.warn(`Skipping unknown property type: ${propertyType} for property: ${propertyName}`)
        break
    }
  })

  // Create a much simpler schema structure
  const schemaWithDescriptionAndIcon = z.object({
    properties: z.object(schemaFields),
    description: z.array(blockSchema).nullable(),
    icon: iconSchema,
  })

  return schemaWithDescriptionAndIcon
}

/**
 * Helper function to find the title property from the database schema
 * @param database - The Notion database object
 * @returns The name of the title property or null if not found
 */
export function findTitleProperty(database: any): string | null {
  const properties = database.properties || {}

  for (const [propertyName, propertyConfig] of Object.entries(properties)) {
    if ((propertyConfig as any).type === "title") {
      return propertyName
    }
  }

  return null
}

/**
 * Helper function to extract task title from properties data
 * @param propertiesData - The properties data object
 * @param titlePropertyName - The name of the title property
 * @returns The task title or null if not found
 */
export function extractTaskTitle(propertiesData: Record<string, any>, titlePropertyName: string | null): string | null {
  if (!titlePropertyName || !propertiesData[titlePropertyName]) {
    return null
  }

  const titleProp = propertiesData[titlePropertyName]
  return titleProp?.title?.[0]?.text?.content || null
}

/**
 * Helper function to get property information for AI context
 * @param database - The Notion database object
 * @returns A string describing the available properties and their types
 */
export function getPropertyDescriptions(database: any): string {
  const properties = database.properties || {}
  const descriptions: string[] = []

  Object.entries(properties).forEach(([propertyName, propertyConfig]: [string, any]) => {
    const propertyType = (propertyConfig as any).type
    descriptions.push(`"${propertyName}" (${propertyType})`)
  })

  return descriptions.join(", ")
}
