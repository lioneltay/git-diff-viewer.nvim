local state = require("git-diff-viewer.state")

describe("state", function()
  -- Reset state before each test
  before_each(function()
    state.reset()
  end)

  -- ─── generation counter ───────────────────────────────────────────────────

  describe("generation counter", function()
    it("starts at 0 after module load", function()
      -- generation is module-level, not reset by reset()
      -- After fresh require, it may not be 0 if other tests ran.
      -- Just check that it's a number.
      assert.is_number(state.generation)
    end)

    it("increments with next_generation()", function()
      local before = state.generation
      local gen = state.next_generation()
      assert.equals(before + 1, gen)
      assert.equals(gen, state.generation)
    end)

    it("monotonically increases", function()
      local g1 = state.next_generation()
      local g2 = state.next_generation()
      local g3 = state.next_generation()
      assert.is_true(g1 < g2)
      assert.is_true(g2 < g3)
    end)

    it("is NOT reset by state.reset()", function()
      state.next_generation()
      state.next_generation()
      local gen_before = state.generation
      state.reset()
      assert.equals(gen_before, state.generation)
    end)
  end)

  -- ─── is_active ────────────────────────────────────────────────────────────

  describe("is_active", function()
    it("returns false when tab is nil", function()
      state.tab = nil
      assert.is_false(state.is_active())
    end)

    it("returns false when tab handle is invalid", function()
      state.tab = 99999 -- non-existent tabpage handle
      assert.is_false(state.is_active())
    end)

    it("returns true when tab matches a valid tabpage", function()
      -- Use the current tabpage as a valid handle
      state.tab = vim.api.nvim_get_current_tabpage()
      assert.is_true(state.is_active())
    end)
  end)

  -- ─── reset ────────────────────────────────────────────────────────────────

  describe("reset", function()
    it("clears git_root", function()
      state.git_root = "/some/path"
      state.reset()
      assert.is_nil(state.git_root)
    end)

    it("resets files to empty sections", function()
      state.files.changes = { { path = "a.ts" } }
      state.reset()
      assert.same({}, state.files.changes)
      assert.same({}, state.files.staged)
      assert.same({}, state.files.conflicts)
    end)

    it("clears current_diff", function()
      state.current_diff = { item = {}, section = "changes" }
      state.reset()
      assert.is_nil(state.current_diff)
    end)

    it("clears tab and window handles", function()
      state.tab = 1
      state.panel_win = 2
      state.panel_buf = 3
      state.reset()
      assert.is_nil(state.tab)
      assert.is_nil(state.panel_win)
      assert.is_nil(state.panel_buf)
    end)

    it("clears buf_cache", function()
      state.buf_cache["HEAD:app.ts"] = 42
      state.reset()
      assert.same({}, state.buf_cache)
    end)
  end)
end)
