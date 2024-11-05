import { Type } from "@sinclair/typebox"

/** String or Integer ID for API */
export const TInputId = Type.Union([Type.String(), Type.Integer()])

export const normalizeId = (id: string | number): number => {
  return typeof id === "string" ? parseInt(id) : id
}
