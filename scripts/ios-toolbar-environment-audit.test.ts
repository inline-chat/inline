import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { auditToolbarDependency } from "./ios-toolbar-environment-audit";

const fixtureRoot = join(import.meta.dir, "fixtures/ios-toolbar-environment");

function audit(name: string) {
  const source = readFileSync(join(fixtureRoot, `${name}.swift`), "utf8");
  return auditToolbarDependency({
    toolbarSource: source,
    hostSource: source,
    viewName: "ChatToolbarLeadingView",
    dependencyType: "Router",
    dependencyName: "router",
  });
}

describe("iOS toolbar type-environment audit", () => {
  test("classifies the build-1178 required environment shape as unsafe at a principal toolbar boundary", () => {
    const result = audit("required-environment");
    expect(result.strategy).toBe("required-environment");
    expect(result.requiredEnvironmentLines).toEqual([6]);
    expect(result.toolbarPlacements).toEqual(["principal"]);
  });

  test("recognizes the optional environment fallback experiment without claiming explicit injection", () => {
    const result = audit("optional-environment");
    expect(result.strategy).toBe("optional-environment");
    expect(result.optionalEnvironmentLines).toEqual([6]);
    expect(result.hasExplicitStoredDependency).toBeFalse();
  });

  test("recognizes the selected explicit dependency experiment", () => {
    const result = audit("explicit-dependency");
    expect(result.strategy).toBe("explicit-dependency");
    expect(result.requiredEnvironmentLines).toEqual([]);
    expect(result.hasExplicitStoredDependency).toBeTrue();
    expect(result.hasExplicitInitializerParameter).toBeTrue();
    expect(result.hostPassesExplicitDependency).toBeTrue();
  });
});
