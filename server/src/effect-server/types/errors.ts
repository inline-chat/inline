import { Schema } from "effect"

/** Safe validation failure. Raw input and parser details are intentionally not retained. */
export class InvalidInputError extends Schema.TaggedErrorClass<InvalidInputError>()("InvalidInputError", {
  field: Schema.optional(Schema.String),
}) {}

export class UnauthorizedError extends Schema.TaggedErrorClass<UnauthorizedError>()("UnauthorizedError", {}) {}

export class ForbiddenError extends Schema.TaggedErrorClass<ForbiddenError>()("ForbiddenError", {}) {}

export class NotFoundError extends Schema.TaggedErrorClass<NotFoundError>()("NotFoundError", {
  resource: Schema.String,
  identifier: Schema.optional(Schema.String),
}) {}

export class ConflictError extends Schema.TaggedErrorClass<ConflictError>()("ConflictError", {
  resource: Schema.String,
}) {}

export type DomainError =
  | InvalidInputError
  | UnauthorizedError
  | ForbiddenError
  | NotFoundError
  | ConflictError
