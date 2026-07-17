const escapeHatches = new Set(["die", "dieMessage", "orDie", "orDieWith"])

const escapeHatchMessage =
  "Keep expected failures in Effect's typed error channel; map them at an explicit boundary instead of using die/orDie. At a true process or adapter boundary, add a narrow reasoned suppression. Skill: $effect-typed-errors."

const suppressionReasonMessage =
  "Inline Effect suppressions require a specific `-- boundary: ...`, `-- compatibility: ...`, or `-- generated: ...` reason. Skill: $effect-typed-errors."

const blanketSuppressionMessage =
  "Do not use file-wide Inline Effect suppressions. Suppress only the exact boundary line and include a specific reason. Skill: $effect-typed-errors."

const normalizeFilename = (filename) => filename.replaceAll("\\", "/")

const isTestLike = (filename) => {
  const normalized = normalizeFilename(filename)
  return (
    normalized.includes("/__tests__/") ||
    /\.(?:spec|test)\.[cm]?[jt]sx?$/.test(normalized)
  )
}

const propertyName = (node) => {
  if (!node) return undefined
  if (node.type === "Identifier") return node.name
  if (node.type === "Literal" || node.type === "StringLiteral") return node.value
  return undefined
}

const noEffectEscapeHatch = {
  meta: {
    type: "problem",
    docs: {
      description: "Disallow Effect die/orDie escape hatches outside test code.",
    },
  },
  create(context) {
    if (isTestLike(context.filename)) return {}

    const effectBindings = new Set()

    return {
      ImportDeclaration(node) {
        const source = node.source?.value

        if (source === "effect") {
          for (const specifier of node.specifiers) {
            if (
              specifier.type === "ImportSpecifier" &&
              propertyName(specifier.imported) === "Effect"
            ) {
              effectBindings.add(specifier.local.name)
            }
          }
        }

        if (source === "effect/Effect") {
          for (const specifier of node.specifiers) {
            if (specifier.type === "ImportNamespaceSpecifier") {
              effectBindings.add(specifier.local.name)
            }

            if (
              specifier.type === "ImportSpecifier" &&
              escapeHatches.has(propertyName(specifier.imported))
            ) {
              context.report({ node: specifier, message: escapeHatchMessage })
            }
          }
        }
      },
      MemberExpression(node) {
        if (
          node.object?.type === "Identifier" &&
          effectBindings.has(node.object.name) &&
          escapeHatches.has(propertyName(node.property))
        ) {
          context.report({ node, message: escapeHatchMessage })
        }
      },
    }
  },
}

const requireSuppressionReason = {
  meta: {
    type: "problem",
    docs: {
      description: "Require narrow, reasoned suppressions for Inline Effect rules.",
    },
  },
  create(context) {
    return {
      Program(node) {
        for (const comment of context.sourceCode.getAllComments()) {
          const value = comment.value.trim()
          if (!/\binline-effect\/[a-z0-9-]+\b/i.test(value)) continue
          if (!/^oxlint-disable(?:\s|$)/.test(value)) {
            if (/--\s*(?:boundary|compatibility|generated):\s*\S/i.test(value)) continue
            context.report({ node: comment, message: suppressionReasonMessage })
            continue
          }

          context.report({ node: comment ?? node, message: blanketSuppressionMessage })
        }
      },
    }
  },
}

export default {
  meta: {
    name: "inline-effect",
  },
  rules: {
    "no-effect-escape-hatch": noEffectEscapeHatch,
    "require-suppression-reason": requireSuppressionReason,
  },
}
