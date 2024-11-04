import { Type } from "@sinclair/typebox"

export const TInputId = Type.Union([Type.String(), Type.Integer()])
