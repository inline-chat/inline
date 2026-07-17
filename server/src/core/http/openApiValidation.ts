const HTTP_OPERATIONS = new Set([
  "delete",
  "get",
  "head",
  "options",
  "patch",
  "post",
  "put",
  "trace",
])

const PATH_ITEM_FIELDS = new Set([
  "$ref",
  "description",
  "parameters",
  "servers",
  "summary",
])

const RESPONSE_STATUS_PATTERN = /^(?:default|[1-5](?:[0-9]{2}|XX))$/

type JsonRecord = Record<string, unknown>

const fail: (
  label: string,
  path: string,
  message: string,
) => never = (label, path, message) => {
  throw new Error(`${label} is not valid OpenAPI at ${path}: ${message}`)
}

const expectRecord = (
  value: unknown,
  label: string,
  path: string,
): JsonRecord => {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value)
  ) {
    return fail(label, path, "expected an object")
  }
  return value as JsonRecord
}

const expectNonEmptyString = (
  value: unknown,
  label: string,
  path: string,
): string => {
  if (typeof value !== "string" || value.length === 0) {
    return fail(label, path, "expected a non-empty string")
  }
  return value
}

const assertJsonCompatible = (
  value: unknown,
  label: string,
  path: string,
  ancestors: Set<object>,
): void => {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean"
  ) {
    return
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      fail(label, path, "numbers must be finite")
    }
    return
  }
  if (value === undefined || typeof value !== "object") {
    return fail(label, path, `unsupported JSON value ${typeof value}`)
  }
  if (ancestors.has(value)) {
    fail(label, path, "cyclic values are not serializable")
  }

  ancestors.add(value)
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      assertJsonCompatible(item, label, `${path}/${index}`, ancestors)
    })
  } else {
    for (const [key, item] of Object.entries(value)) {
      assertJsonCompatible(item, label, `${path}/${key}`, ancestors)
    }
  }
  ancestors.delete(value)
}

const resolveLocalReference = (
  root: JsonRecord,
  reference: string,
): unknown => {
  if (reference === "#") {
    return root
  }
  if (!reference.startsWith("#/")) {
    return undefined
  }

  let current: unknown = root
  for (const encodedPart of reference.slice(2).split("/")) {
    const part = encodedPart.replaceAll("~1", "/").replaceAll("~0", "~")
    if (
      current === null ||
      typeof current !== "object" ||
      !(part in current)
    ) {
      return undefined
    }
    current = (current as JsonRecord)[part]
  }
  return current
}

const assertReferencesResolve = (
  value: unknown,
  root: JsonRecord,
  label: string,
  path: string,
): void => {
  if (value === null || typeof value !== "object") {
    return
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      assertReferencesResolve(item, root, label, `${path}/${index}`)
    })
    return
  }

  for (const [key, item] of Object.entries(value)) {
    const itemPath = `${path}/${key}`
    if (
      key === "$ref" &&
      typeof item === "string" &&
      item.startsWith("#") &&
      resolveLocalReference(root, item) === undefined
    ) {
      fail(label, itemPath, `unresolved local reference ${item}`)
    }
    assertReferencesResolve(item, root, label, itemPath)
  }
}

const assertResponses = (
  operation: JsonRecord,
  label: string,
  path: string,
): void => {
  const responses = expectRecord(
    operation["responses"],
    label,
    `${path}/responses`,
  )
  const entries = Object.entries(responses)
  if (entries.length === 0) {
    fail(label, `${path}/responses`, "expected at least one response")
  }

  for (const [status, response] of entries) {
    if (!RESPONSE_STATUS_PATTERN.test(status)) {
      fail(label, `${path}/responses/${status}`, "invalid response status")
    }
    expectRecord(response, label, `${path}/responses/${status}`)
  }
}

/**
 * Focused structural validation for generated OpenAPI 3.1 documents.
 *
 * This catches non-JSON values, broken local references, malformed path
 * entries, missing responses, duplicate operation IDs, and invalid top-level
 * metadata before a generated document can be accepted as a drift fixture.
 */
export const assertValidOpenApiDocument: (
  document: unknown,
  label?: string,
) => asserts document is JsonRecord = (
  document,
  label = "OpenAPI document",
) => {
  const root = expectRecord(document, label, "#")
  assertJsonCompatible(root, label, "#", new Set())

  if (root["openapi"] !== "3.1.0") {
    fail(label, "#/openapi", "expected version 3.1.0")
  }
  const info = expectRecord(root["info"], label, "#/info")
  expectNonEmptyString(info["title"], label, "#/info/title")
  expectNonEmptyString(info["version"], label, "#/info/version")

  const paths = expectRecord(root["paths"], label, "#/paths")
  const operationIds = new Set<string>()
  for (const [routePath, pathValue] of Object.entries(paths)) {
    if (!routePath.startsWith("/")) {
      fail(label, `#/paths/${routePath}`, "route paths must start with /")
    }
    const pathItem = expectRecord(
      pathValue,
      label,
      `#/paths/${routePath}`,
    )
    for (const [field, fieldValue] of Object.entries(pathItem)) {
      if (
        !HTTP_OPERATIONS.has(field) &&
        !PATH_ITEM_FIELDS.has(field) &&
        !field.startsWith("x-")
      ) {
        fail(
          label,
          `#/paths/${routePath}/${field}`,
          "unknown path-item field",
        )
      }
      if (!HTTP_OPERATIONS.has(field)) {
        continue
      }

      const operationPath = `#/paths/${routePath}/${field}`
      const operation = expectRecord(fieldValue, label, operationPath)
      assertResponses(operation, label, operationPath)
      if (operation["operationId"] !== undefined) {
        const operationId = expectNonEmptyString(
          operation["operationId"],
          label,
          `${operationPath}/operationId`,
        )
        if (operationIds.has(operationId)) {
          fail(
            label,
            `${operationPath}/operationId`,
            `duplicate operationId ${operationId}`,
          )
        }
        operationIds.add(operationId)
      }
    }
  }

  if (root["components"] !== undefined) {
    expectRecord(root["components"], label, "#/components")
  }
  assertReferencesResolve(root, root, label, "#")
}
