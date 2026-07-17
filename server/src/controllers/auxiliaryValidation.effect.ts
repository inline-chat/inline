import {
  Data,
  Effect,
  ErrorReporter as EffectErrorReporter,
  Schema,
} from "effect"
import {
  HttpServerResponse,
} from "effect/unstable/http"
import {
  HttpApiSchema,
} from "effect/unstable/httpapi"
import {
  LegacyElysiaJsonParseError,
  parseLegacyElysiaBody,
} from "../core/http/legacyElysiaBody"

const OptionalUnknown = Schema.optionalKey(Schema.Unknown)

export const LegacyValidationIssue = Schema.Struct({
  type: Schema.Number,
  schema: Schema.Record(Schema.String, Schema.Unknown),
  path: Schema.String,
  value: OptionalUnknown,
  message: Schema.String,
  errors: Schema.Array(Schema.Unknown),
  summary: Schema.String,
}).annotate({
  identifier: "AuxiliaryLegacyValidationIssue",
})

export const LegacyValidationError = Schema.Struct({
  type: Schema.Literal("validation"),
  on: Schema.Literals(["body", "query"]),
  property: Schema.String,
  message: Schema.String,
  summary: Schema.String,
  expected: Schema.Record(Schema.String, Schema.Unknown),
  found: OptionalUnknown,
  errors: Schema.Array(LegacyValidationIssue),
}).pipe(
  HttpApiSchema.status(422),
).annotate({
  identifier: "AuxiliaryLegacyValidationError",
})

export const LegacyBadRequest = Schema.Literal(
  "Bad Request",
).pipe(
  HttpApiSchema.status(400),
  HttpApiSchema.asText(),
).annotate({
  identifier: "AuxiliaryLegacyBadRequest",
})

export const AuxiliaryInternalServerError = Schema.Literal(
  "Internal Server Error",
).pipe(
  HttpApiSchema.status(500),
  HttpApiSchema.asText(),
).annotate({
  identifier: "AuxiliaryInternalServerError",
})

export class AuxiliaryRequestRejected extends Data.TaggedError(
  "AuxiliaryRequestRejected",
)<{
  readonly response: HttpServerResponse.HttpServerResponse
}> {
  override readonly [EffectErrorReporter.ignore] = true
}

export class AuxiliaryRequestParsingFailure extends Data.TaggedError(
  "AuxiliaryRequestParsingFailure",
)<{
  readonly cause: unknown
}> {}

export interface LegacyStringField {
  readonly name: string
  readonly required: boolean
}

const rawResponse = (
  body: string,
  status: number,
  contentType?: string,
): HttpServerResponse.HttpServerResponse =>
  HttpServerResponse.raw(
    new TextEncoder().encode(body),
    {
      status,
      ...(contentType === undefined
        ? {}
        : {
            headers: {
              "content-type": contentType,
            },
          }),
    },
  )

export const auxiliaryInternalServerError =
  (): HttpServerResponse.HttpServerResponse =>
    rawResponse("Internal Server Error", 500)

const badRequest = (): HttpServerResponse.HttpServerResponse =>
  rawResponse("Bad Request", 400)

const isRecord = (
  value: unknown,
): value is Record<string, unknown> =>
  typeof value === "object" &&
  value !== null &&
  !Array.isArray(value)

const describeValue = (value: unknown): string => {
  if (value === undefined) {
    return "undefined"
  }

  const encoded = JSON.stringify(value)
  return encoded ?? String(value)
}

const expectedValue = (
  fields: ReadonlyArray<LegacyStringField>,
): Record<string, string> =>
  Object.fromEntries(
    fields
      .filter((field) => field.required)
      .map((field) => [field.name, ""]),
  )

const objectSchema = (
  fields: ReadonlyArray<LegacyStringField>,
): Record<string, unknown> => ({
  type: "object",
  required: fields
    .filter((field) => field.required)
    .map((field) => field.name),
  properties: Object.fromEntries(
    fields.map((field) => [
      field.name,
      { type: "string" },
    ]),
  ),
  additionalProperties: false,
})

const validationBody = (
  target: "body" | "query",
  value: unknown,
  fields: ReadonlyArray<LegacyStringField>,
): typeof LegacyValidationError.Type => {
  const expected = expectedValue(fields)

  if (!isRecord(value)) {
    const summary = "Expected object"
    return {
      type: "validation",
      on: target,
      property: "root",
      message: summary,
      summary,
      expected,
      errors: [
        {
          summary,
          type: 46,
          schema: objectSchema(fields),
          path: "",
          message: summary,
          errors: [],
        },
      ],
    }
  }

  const issues = fields.flatMap((field) => {
    const fieldValue = value[field.name]
    if (
      typeof fieldValue === "string" ||
      (fieldValue === undefined && !field.required)
    ) {
      return []
    }

    const summary =
      `Expected property '${field.name}' to be string but found: ${describeValue(fieldValue)}`
    return [{
      type: 54,
      schema: { type: "string" },
      path: `/${field.name}`,
      ...(fieldValue === undefined
        ? {}
        : { value: fieldValue }),
      message: "Expected string",
      errors: [],
      summary,
    }]
  })
  const first = issues[0]

  return {
    type: "validation",
    on: target,
    property: first?.path ?? "root",
    message: first?.message ?? "Expected object",
    summary: first?.summary ?? "Expected object",
    expected,
    found: value,
    errors: issues,
  }
}

const validationResponse = (
  target: "body" | "query",
  value: unknown,
  fields: ReadonlyArray<LegacyStringField>,
): HttpServerResponse.HttpServerResponse =>
  rawResponse(
    JSON.stringify(
      validationBody(target, value, fields),
      undefined,
      2,
    ),
    422,
    "application/json",
  )

export const decodeLegacyStringObject = <A>(
  schema: Schema.Decoder<A>,
  target: "body" | "query",
  value: unknown,
  fields: ReadonlyArray<LegacyStringField>,
): Effect.Effect<A, AuxiliaryRequestRejected> =>
  Schema.decodeUnknownEffect(schema)(value).pipe(
    Effect.mapError(
      () =>
        new AuxiliaryRequestRejected({
          response: validationResponse(
            target,
            value,
            fields,
          ),
        }),
    ),
  )

export const decodeLegacyJsonBody = <A>(
  request: Request,
  schema: Schema.Decoder<A>,
  fields: ReadonlyArray<LegacyStringField>,
): Effect.Effect<
  A,
  AuxiliaryRequestParsingFailure | AuxiliaryRequestRejected
> =>
  Effect.tryPromise({
    try: () => parseLegacyElysiaBody(request),
    catch: (cause) =>
      cause instanceof LegacyElysiaJsonParseError
        ? new AuxiliaryRequestRejected({
            response: badRequest(),
          })
        : new AuxiliaryRequestParsingFailure({ cause }),
  }).pipe(
    Effect.flatMap((value) =>
      decodeLegacyStringObject(
        schema,
        "body",
        value,
        fields,
      ),
    ),
  )

export const queryRecord = (
  request: Request,
): Record<string, string> =>
  Object.fromEntries(new URL(request.url).searchParams)
