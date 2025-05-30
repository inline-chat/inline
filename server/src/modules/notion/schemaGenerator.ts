import { z } from "zod"
import { Log } from "@in/server/utils/log"

const log = new Log("NotionSchemaGenerator")

/**
 * Generates a dynamic Zod schema based on Notion database properties
 * @param database - The Notion database object with properties
 * @returns A Zod schema that matches the database structure
 */
export function generateNotionPropertiesSchema(database: any): z.ZodType<any> {
  const properties = database.properties || {}
  const schemaFields: Record<string, z.ZodType<any>> = {}

  Object.entries(properties).forEach(([propertyName, propertyConfig]: [string, any]) => {
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

      case "relation":
        schemaFields[propertyName] = z
          .object({
            relation: z.array(
              z.object({
                id: z.string(),
              }),
            ),
          })
          .nullable()
        break

      case "files":
        schemaFields[propertyName] = z
          .object({
            files: z.array(
              z.object({
                name: z.string(),
                type: z.enum(["external", "file"]),
                external: z
                  .object({
                    url: z.string(),
                  })
                  .nullable(),
                file: z
                  .object({
                    url: z.string(),
                    expiry_time: z.string(),
                  })
                  .nullable(),
              }),
            ),
          })
          .nullable()
        break

      case "unique_id":
        schemaFields[propertyName] = z
          .object({
            unique_id: z.object({
              number: z.number().nullable(),
              prefix: z.string().nullable(),
            }),
          })
          .nullable()
        break

      case "formula":
        // Formula properties are read-only, so we don't include them in the schema
        break

      case "rollup":
        // Rollup properties are read-only, so we don't include them in the schema
        break

      case "created_time":
      case "last_edited_time":
        // These are automatically managed by Notion
        break

      case "created_by":
      case "last_edited_by":
        // These are automatically managed by Notion
        break

      default:
        // For unknown property types, create a flexible schema
        log.warn(`Unknown property type: ${propertyType} for property: ${propertyName}`)
        schemaFields[propertyName] = z.null()
        break
    }
  })

  // Add description field to the schema
  const schemaWithDescription = z.object({
    properties: z.object(schemaFields).strict(),
    description: z
      .array(
        z.object({
          object: z.literal("block"),
          type: z.literal("paragraph"),
          paragraph: z.object({
            rich_text: z.array(
              z.object({
                type: z.literal("text"),
                text: z.object({
                  content: z.string(),
                }),
              }),
            ),
          }),
        }),
      )
      .nullable(),
  })

  return schemaWithDescription
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
