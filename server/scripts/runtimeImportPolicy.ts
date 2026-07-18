/**
 * Packages that may remain in the legacy oracle and differential tests but
 * must never enter the deployed server bundle.
 */
export const FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN =
  String.raw`^(?:@elysiajs/|elysia(?:$|[-/]))`

export const isForbiddenProductionRuntimeImport = (
  packageName: string,
): boolean =>
  new RegExp(
    FORBIDDEN_PRODUCTION_RUNTIME_IMPORT_PATTERN,
  ).test(packageName)
