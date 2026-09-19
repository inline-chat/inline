const runners = new Set(["bun:test", "vitest", "@effect/vitest"])
const propertyName = (node) => node?.name ?? node?.value
const rootName = (node) => {
  if (node?.type === "Identifier") return node.name
  if (node?.type === "MemberExpression") return rootName(node.object)
  if (node?.type === "CallExpression") return rootName(node.callee)
  return undefined
}

export default {
  meta: { name: "inline-tests" },
  rules: {
    "no-focused-tests": {
      meta: { type: "problem", docs: { description: "Reject focused Bun, Vitest and Effect tests, including aliased imports." } },
      create(context) {
        const bindings = new Set()
        return {
          ImportDeclaration(node) {
            if (!runners.has(node.source.value)) return
            for (const specifier of node.specifiers) {
              if (specifier.type === "ImportNamespaceSpecifier" ||
                (specifier.type === "ImportSpecifier" && ["test", "it", "describe", "suite"].includes(propertyName(specifier.imported)))) {
                bindings.add(specifier.local.name)
              }
            }
          },
          MemberExpression(node) {
            if (propertyName(node.property) === "only" && bindings.has(rootName(node.object))) {
              context.report({ node, message: "Remove focused tests before accepting the suite; .only can hide regressions." })
            }
          },
        }
      },
    },
  },
}
