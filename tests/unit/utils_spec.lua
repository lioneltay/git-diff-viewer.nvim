local utils = require("git-diff-viewer.utils")

describe("utils", function()
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

  -- ─── fuzzy_match ──────────────────────────────────────────────────────────

  describe("fuzzy_match", function()
    it("matches empty query to any string", function()
      assert.is_true(utils.fuzzy_match("anything", ""))
    end)

    it("matches exact substring", function()
      assert.is_true(utils.fuzzy_match("src/components/Button.tsx", "Button"))
    end)

    it("matches fuzzy characters in order", function()
      assert.is_true(utils.fuzzy_match("src/components/Button.tsx", "scbt"))
    end)

    it("rejects characters out of order", function()
      assert.is_false(utils.fuzzy_match("abc", "cb"))
    end)

    it("rejects query with missing characters", function()
      assert.is_false(utils.fuzzy_match("abc", "abz"))
    end)

    it("is case insensitive", function()
      assert.is_true(utils.fuzzy_match("Button.tsx", "btn"))
      assert.is_true(utils.fuzzy_match("button.tsx", "BTN"))
    end)

    it("matches full path fuzzy", function()
      assert.is_true(utils.fuzzy_match("lua/git-diff-viewer/ui/panel.lua", "pnl"))
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
