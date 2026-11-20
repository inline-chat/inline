/**
 * The retired Elysia HTTP package family, which must never re-enter the
 * deployed server bundle.
 */
export const FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN =
  String.raw`^(?:@elysiajs/|elysia(?:$|[-/]))`

export const isForbiddenProductionRuntimeImport = (
  packageName: string,
): boolean =>
  new RegExp(
    FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN,
  ).test(packageName)
