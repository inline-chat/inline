import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { setOpenClawAgentDefaultModel } from "./openclaw-compat.js"

describe("OpenClaw agent config compatibility", () => {
  it("updates only the selected agent in a legacy list", () => {
    const cfg = {
      agents: {
        defaults: { model: "openai/default" },
        list: [
          { id: "main", model: "openai/old", name: "Main" },
          { id: "other", model: "openai/other" },
        ],
      },
    }
    setOpenClawAgentDefaultModel(cfg as OpenClawConfig, "main", "openai/new")
    expect(cfg.agents.list).toEqual([
      { id: "main", model: "openai/new", name: "Main" },
      { id: "other", model: "openai/other" },
    ])
    expect(cfg.agents.defaults.model).toBe("openai/default")
    expect(cfg.agents).not.toHaveProperty("entries")
  })

  it("updates only the selected agent in current keyed entries", () => {
    const cfg = {
      agents: {
        defaults: { model: "openai/default" },
        entries: {
          main: { model: "openai/old", name: "Main" },
          other: { model: "openai/other" },
        },
      },
    }
    setOpenClawAgentDefaultModel(cfg as OpenClawConfig, "main", "openai/new")
    expect(cfg.agents.entries).toEqual({
      main: { model: "openai/new", name: "Main" },
      other: { model: "openai/other" },
    })
    expect(cfg.agents.defaults.model).toBe("openai/default")
    expect(cfg.agents).not.toHaveProperty("list")
  })

  it("updates the defaults when there is no explicit agent entry", () => {
    const cfg = { agents: { defaults: { model: "openai/old", workspace: "/workspace" } } }
    setOpenClawAgentDefaultModel(cfg as OpenClawConfig, "main", "openai/new")
    expect(cfg.agents.defaults).toEqual({ model: "openai/new", workspace: "/workspace" })
  })

  it("creates default model config when agents is absent", () => {
    const cfg: OpenClawConfig = {}
    setOpenClawAgentDefaultModel(cfg, "main", "openai/new")
    expect(cfg).toEqual({ agents: { defaults: { model: "openai/new" } } })
  })

  it("uses own keyed entries instead of object prototype properties", () => {
    const cfg = { agents: { entries: {}, defaults: { model: "openai/old" } } }
    setOpenClawAgentDefaultModel(cfg as OpenClawConfig, "constructor", "openai/new")
    expect(cfg.agents.defaults.model).toBe("openai/new")
    expect(cfg.agents.entries).toEqual({})
  })
})
