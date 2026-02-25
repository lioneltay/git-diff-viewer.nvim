local utils = require("git-diff-viewer.utils")

describe("utils", function()
  -- ─── path_to_ft ────────────────────────────────────────────────────────────

  describe("path_to_ft", function()
    it("returns empty string for nil path", function()
      assert.equals("", utils.path_to_ft(nil))
    end)

    it("returns typescript for .ts files", function()
      assert.equals("typescript", utils.path_to_ft("src/app.ts"))
    end)

    it("returns typescriptreact for .tsx files", function()
      assert.equals("typescriptreact", utils.path_to_ft("Component.tsx"))
    end)

    it("returns javascript for .js files", function()
      assert.equals("javascript", utils.path_to_ft("index.js"))
    end)

    it("returns lua for .lua files", function()
      assert.equals("lua", utils.path_to_ft("init.lua"))
    end)

    it("returns python for .py files", function()
      assert.equals("python", utils.path_to_ft("main.py"))
    end)

    it("returns go for .go files", function()
      assert.equals("go", utils.path_to_ft("main.go"))
    end)

    it("returns rust for .rs files", function()
      assert.equals("rust", utils.path_to_ft("lib.rs"))
    end)

    it("returns json for .json files", function()
      assert.equals("json", utils.path_to_ft("package.json"))
    end)

    it("returns yaml for .yml files", function()
      assert.equals("yaml", utils.path_to_ft("config.yml"))
    end)

    it("returns yaml for .yaml files", function()
      assert.equals("yaml", utils.path_to_ft("config.yaml"))
    end)

    it("returns markdown for .md files", function()
      assert.equals("markdown", utils.path_to_ft("README.md"))
    end)

    it("returns html for .html files", function()
      assert.equals("html", utils.path_to_ft("index.html"))
    end)

    it("returns css for .css files", function()
      assert.equals("css", utils.path_to_ft("style.css"))
    end)

    it("returns sh for .sh files", function()
      assert.equals("sh", utils.path_to_ft("script.sh"))
    end)

    it("handles case insensitivity", function()
      assert.equals("typescript", utils.path_to_ft("File.TS"))
    end)

    it("handles dockerfile basename", function()
      assert.equals("dockerfile", utils.path_to_ft("Dockerfile"))
    end)

    it("handles makefile basename", function()
      assert.equals("make", utils.path_to_ft("Makefile"))
    end)

    -- Bug #26: unknown extensions should return empty string, not raw extension
    it("returns raw extension for unknown types (current behavior)", function()
      -- This will be changed in bug fix phase to return ""
      local result = utils.path_to_ft("file.xyz")
      assert.equals("xyz", result)
    end)

    it("handles deeply nested paths", function()
      assert.equals("typescriptreact", utils.path_to_ft("src/components/shared/Button.tsx"))
      assert.equals("typescript", utils.path_to_ft("src/components/shared/utils/index.ts"))
    end)
  end)

  -- ─── split_path ────────────────────────────────────────────────────────────

  describe("split_path", function()
    it("splits nested path into dirs and file", function()
      local result = utils.split_path("src/components/Button.tsx")
      assert.same({ "src", "components" }, result.dirs)
      assert.equals("Button.tsx", result.file)
    end)

    it("returns empty dirs for root file", function()
      local result = utils.split_path("main.go")
      assert.same({}, result.dirs)
      assert.equals("main.go", result.file)
    end)

    it("handles single directory", function()
      local result = utils.split_path("src/app.ts")
      assert.same({ "src" }, result.dirs)
      assert.equals("app.ts", result.file)
    end)

    it("handles deeply nested path", function()
      local result = utils.split_path("a/b/c/d/e.ts")
      assert.same({ "a", "b", "c", "d" }, result.dirs)
      assert.equals("e.ts", result.file)
    end)
  end)

  -- ─── dirs_to_path ──────────────────────────────────────────────────────────

  describe("dirs_to_path", function()
    it("joins dirs with /", function()
      assert.equals("src/components", utils.dirs_to_path({ "src", "components" }))
    end)

    it("returns single dir", function()
      assert.equals("src", utils.dirs_to_path({ "src" }))
    end)

    it("returns empty string for empty dirs", function()
      assert.equals("", utils.dirs_to_path({}))
    end)
  end)

  -- ─── status_icon ───────────────────────────────────────────────────────────

  describe("status_icon", function()
    it("returns M for unstaged modified", function()
      assert.equals("M", utils.status_icon(" M", "changes"))
    end)

    it("returns M for staged modified", function()
      assert.equals("M", utils.status_icon("M ", "staged"))
    end)

    it("returns A for staged added", function()
      assert.equals("A", utils.status_icon("A ", "staged"))
    end)

    it("returns D for unstaged deleted", function()
      assert.equals("D", utils.status_icon(" D", "changes"))
    end)

    it("returns D for staged deleted", function()
      assert.equals("D", utils.status_icon("D ", "staged"))
    end)

    it("returns ? for untracked", function()
      assert.equals("?", utils.status_icon("??", "changes"))
    end)

    it("returns R for rename", function()
      assert.equals("R", utils.status_icon("R ", "staged"))
    end)

    it("returns ! for UU conflict", function()
      assert.equals("!", utils.status_icon("UU", "conflicts"))
    end)

    it("returns ! for AA conflict", function()
      assert.equals("!", utils.status_icon("AA", "conflicts"))
    end)

    it("returns ! for DD conflict", function()
      assert.equals("!", utils.status_icon("DD", "conflicts"))
    end)

    it("returns M for MM in changes section", function()
      assert.equals("M", utils.status_icon("MM", "changes"))
    end)

    it("returns M for MM in staged section", function()
      assert.equals("M", utils.status_icon("MM", "staged"))
    end)
  end)

  -- ─── format_counts ─────────────────────────────────────────────────────────

  describe("format_counts", function()
    it("formats both added and removed", function()
      assert.equals("+10 -5", utils.format_counts(10, 5))
    end)

    it("formats only added", function()
      assert.equals("+3", utils.format_counts(3, 0))
    end)

    it("formats only removed", function()
      assert.equals("-7", utils.format_counts(0, 7))
    end)

    it("returns empty for nil/nil (binary)", function()
      assert.equals("", utils.format_counts(nil, nil))
    end)

    it("returns empty for zero/zero", function()
      assert.equals("", utils.format_counts(0, 0))
    end)

    it("handles large numbers", function()
      assert.equals("+1000 -500", utils.format_counts(1000, 500))
    end)
  end)

  -- ─── get_status_hl ─────────────────────────────────────────────────────────

  describe("get_status_hl", function()
    it("returns correct highlight for M", function()
      assert.equals("GitDiffViewerStatusM", utils.get_status_hl("M"))
    end)

    it("returns correct highlight for A", function()
      assert.equals("GitDiffViewerStatusA", utils.get_status_hl("A"))
    end)

    it("returns correct highlight for D", function()
      assert.equals("GitDiffViewerStatusD", utils.get_status_hl("D"))
    end)

    it("returns correct highlight for R", function()
      assert.equals("GitDiffViewerStatusR", utils.get_status_hl("R"))
    end)

    it("returns correct highlight for ?", function()
      assert.equals("GitDiffViewerStatusA", utils.get_status_hl("?"))
    end)

    it("returns correct highlight for !", function()
      assert.equals("GitDiffViewerStatusConflict", utils.get_status_hl("!"))
    end)

    it("returns default for unknown icon", function()
      assert.equals("GitDiffViewerStatusM", utils.get_status_hl("X"))
    end)
  end)
end)
