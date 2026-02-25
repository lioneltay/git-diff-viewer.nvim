local parse = require("git-diff-viewer.parse")

describe("parse", function()
  -- ─── parse_status ──────────────────────────────────────────────────────────

  describe("parse_status", function()
    it("returns empty list for nil input", function()
      assert.same({}, parse.parse_status(nil))
    end)

    it("returns empty list for empty string", function()
      assert.same({}, parse.parse_status(""))
    end)

    it("parses a single modified file", function()
      local raw = " M src/app.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals(" M", entries[1].xy)
      assert.equals("src/app.ts", entries[1].path)
      assert.equals("unstaged", entries[1].status)
      assert.is_nil(entries[1].orig_path)
    end)

    it("parses staged modified file (M_)", function()
      local raw = "M  src/app.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("M ", entries[1].xy)
      assert.equals("staged", entries[1].status)
    end)

    it("parses both modified (MM)", function()
      local raw = "MM src/app.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("MM", entries[1].xy)
      assert.equals("both", entries[1].status)
    end)

    it("parses untracked file", function()
      local raw = "?? newfile.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("??", entries[1].xy)
      assert.equals("untracked", entries[1].status)
    end)

    it("parses staged new file (A_)", function()
      local raw = "A  newfile.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("A ", entries[1].xy)
      assert.equals("staged", entries[1].status)
    end)

    it("parses staged deleted (D_)", function()
      local raw = "D  deleted.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("D ", entries[1].xy)
      assert.equals("staged", entries[1].status)
    end)

    it("parses unstaged deleted (_D)", function()
      local raw = " D deleted.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals(" D", entries[1].xy)
      assert.equals("unstaged", entries[1].status)
    end)

    it("parses rename with orig_path", function()
      local raw = "R  new-name.ts\0old-name.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("R ", entries[1].xy)
      assert.equals("new-name.ts", entries[1].path)
      assert.equals("old-name.ts", entries[1].orig_path)
      assert.equals("staged", entries[1].status)
    end)

    it("parses conflict UU", function()
      local raw = "UU conflict.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("UU", entries[1].xy)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict AA", function()
      local raw = "AA both-added.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict DD", function()
      local raw = "DD both-deleted.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict AU", function()
      local raw = "AU file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict UA", function()
      local raw = "UA file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict DU", function()
      local raw = "DU file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses conflict UD", function()
      local raw = "UD file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("conflict", entries[1].status)
    end)

    it("parses multiple files", function()
      local raw = " M src/a.ts\0M  src/b.ts\0?? src/c.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(3, #entries)
      assert.equals("unstaged", entries[1].status)
      assert.equals("staged", entries[2].status)
      assert.equals("untracked", entries[3].status)
    end)

    it("handles AM status (staged new + unstaged modified)", function()
      local raw = "AM file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("both", entries[1].status)
    end)

    it("handles AD status (staged new + unstaged deleted)", function()
      local raw = "AD file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("both", entries[1].status)
    end)

    it("handles copy status (C does not consume next NUL part)", function()
      -- Current code only checks for R prefix, not C. So C_ treats orig as separate entry.
      local raw = "C  new-copy.ts\0original.ts\0"
      local entries = parse.parse_status(raw)
      -- C is not handled as rename, so orig_path is parsed as a separate (broken) entry
      assert.equals(2, #entries)
      assert.equals("new-copy.ts", entries[1].path)
      assert.is_nil(entries[1].orig_path)
    end)

    it("handles paths with spaces", function()
      local raw = " M my file.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("my file.ts", entries[1].path)
    end)

    it("handles deeply nested paths", function()
      local raw = " M src/components/shared/utils/helpers/deep.ts\0"
      local entries = parse.parse_status(raw)
      assert.equals(1, #entries)
      assert.equals("src/components/shared/utils/helpers/deep.ts", entries[1].path)
    end)
  end)

  -- ─── parse_numstat ─────────────────────────────────────────────────────────

  describe("parse_numstat", function()
    it("returns empty map for nil input", function()
      assert.same({}, parse.parse_numstat(nil))
    end)

    it("returns empty map for empty string", function()
      assert.same({}, parse.parse_numstat(""))
    end)

    it("parses normal counts", function()
      local raw = "10\t5\tsrc/app.ts\0"
      local result = parse.parse_numstat(raw)
      assert.is_not_nil(result["src/app.ts"])
      assert.equals(10, result["src/app.ts"].added)
      assert.equals(5, result["src/app.ts"].removed)
      assert.is_false(result["src/app.ts"].binary)
    end)

    it("parses zero counts", function()
      local raw = "0\t0\tsrc/app.ts\0"
      local result = parse.parse_numstat(raw)
      assert.equals(0, result["src/app.ts"].added)
      assert.equals(0, result["src/app.ts"].removed)
    end)

    it("parses binary file", function()
      local raw = "-\t-\timage.png\0"
      local result = parse.parse_numstat(raw)
      assert.is_not_nil(result["image.png"])
      assert.is_nil(result["image.png"].added)
      assert.is_nil(result["image.png"].removed)
      assert.is_true(result["image.png"].binary)
    end)

    it("parses multiple entries", function()
      local raw = "10\t5\ta.ts" .. "\0" .. "5\t3\tb.ts" .. "\0"
      local result = parse.parse_numstat(raw)
      assert.equals(10, result["a.ts"].added)
      assert.equals(3, result["b.ts"].removed)
    end)

    it("handles large numbers", function()
      local raw = "1000\t500\tsrc/big.ts\0"
      local result = parse.parse_numstat(raw)
      assert.equals(1000, result["src/big.ts"].added)
      assert.equals(500, result["src/big.ts"].removed)
    end)
  end)

  -- ─── build_file_list ───────────────────────────────────────────────────────

  describe("build_file_list", function()
    it("returns empty sections for empty input", function()
      local result = parse.build_file_list({}, {}, {})
      assert.same({}, result.conflicts)
      assert.same({}, result.changes)
      assert.same({}, result.staged)
    end)

    it("puts conflict entries in conflicts section", function()
      local entries = {
        { xy = "UU", path = "conflict.ts", status = "conflict" },
      }
      local result = parse.build_file_list(entries, {}, {})
      assert.equals(1, #result.conflicts)
      assert.equals(0, #result.changes)
      assert.equals(0, #result.staged)
      assert.equals("conflicts", result.conflicts[1].section)
    end)

    it("puts untracked entries in changes section", function()
      local entries = {
        { xy = "??", path = "new.ts", status = "untracked" },
      }
      local result = parse.build_file_list(entries, {}, {})
      assert.equals(0, #result.conflicts)
      assert.equals(1, #result.changes)
      assert.equals(0, #result.staged)
      assert.equals("changes", result.changes[1].section)
    end)

    it("puts unstaged entries in changes section", function()
      local entries = {
        { xy = " M", path = "modified.ts", status = "unstaged" },
      }
      local numstat = { ["modified.ts"] = { added = 5, removed = 2, binary = false } }
      local result = parse.build_file_list(entries, numstat, {})
      assert.equals(1, #result.changes)
      assert.equals(5, result.changes[1].added)
      assert.equals(2, result.changes[1].removed)
    end)

    it("puts staged entries in staged section", function()
      local entries = {
        { xy = "M ", path = "staged.ts", status = "staged" },
      }
      local numstat = { ["staged.ts"] = { added = 3, removed = 1, binary = false } }
      local result = parse.build_file_list(entries, {}, numstat)
      assert.equals(1, #result.staged)
      assert.equals(3, result.staged[1].added)
      assert.equals(1, result.staged[1].removed)
    end)

    it("splits both (MM) into changes AND staged", function()
      local entries = {
        { xy = "MM", path = "both.ts", status = "both" },
      }
      local unstaged = { ["both.ts"] = { added = 10, removed = 5, binary = false } }
      local staged = { ["both.ts"] = { added = 3, removed = 1, binary = false } }
      local result = parse.build_file_list(entries, unstaged, staged)
      assert.equals(1, #result.changes)
      assert.equals(1, #result.staged)
      assert.equals("changes", result.changes[1].section)
      assert.equals("staged", result.staged[1].section)
      assert.equals(10, result.changes[1].added)
      assert.equals(3, result.staged[1].added)
    end)

    it("preserves orig_path for renames", function()
      local entries = {
        { xy = "R ", path = "new.ts", orig_path = "old.ts", status = "staged" },
      }
      local result = parse.build_file_list(entries, {}, {})
      assert.equals(1, #result.staged)
      assert.equals("new.ts", result.staged[1].path)
      assert.equals("old.ts", result.staged[1].orig_path)
    end)

    it("marks binary files", function()
      local entries = {
        { xy = " M", path = "image.png", status = "unstaged" },
      }
      local numstat = { ["image.png"] = { binary = true } }
      local result = parse.build_file_list(entries, numstat, {})
      assert.is_true(result.changes[1].binary)
    end)

    it("handles mixed entries", function()
      local entries = {
        { xy = "UU", path = "conflict.ts", status = "conflict" },
        { xy = " M", path = "changed.ts", status = "unstaged" },
        { xy = "M ", path = "staged.ts", status = "staged" },
        { xy = "??", path = "new.ts", status = "untracked" },
        { xy = "MM", path = "both.ts", status = "both" },
      }
      local result = parse.build_file_list(entries, {}, {})
      assert.equals(1, #result.conflicts)
      assert.equals(3, #result.changes) -- changed + new + both(changes half)
      assert.equals(2, #result.staged) -- staged + both(staged half)
    end)
  end)
end)
