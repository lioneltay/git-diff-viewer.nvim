-- pr_picker.lua — Floating PR picker with local fuzzy search
--
-- Three-window layout: input (top-left), list (bottom-left), preview (right).
-- Fetches all open PRs once via `gh pr list`, then filters locally.
-- Opens immediately with a loading state; data populates asynchronously.

local M = {}

local gh = require("git-diff-viewer.gh")
local utils = require("git-diff-viewer.utils")

local ns = vim.api.nvim_create_namespace("git_diff_viewer_pr_picker")

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function relative_time(iso_str)
  if not iso_str then return "" end
  local y, mo, d, h, mi, s = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return iso_str:sub(1, 10) end
  -- Both timestamps go through os.time() which treats fields as local time.
  -- Since both are actually UTC, the timezone offset cancels out in the diff.
  local now = os.time(os.date("!*t"))
  local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  local diff = now - ts
  if diff < 0 then diff = 0 end
  if diff < 60 then return "just now" end
  if diff < 3600 then
    local n = math.floor(diff / 60)
    return n .. (n == 1 and " minute ago" or " minutes ago")
  end
  if diff < 86400 then
    local n = math.floor(diff / 3600)
    return n .. (n == 1 and " hour ago" or " hours ago")
  end
  if diff < 604800 then
    local n = math.floor(diff / 86400)
    return n .. (n == 1 and " day ago" or " days ago")
  end
  return iso_str:sub(1, 10)
end

-- ── Preview formatting ──────────────────────────────────────────────────────

local function build_preview_lines(pr)
  local lines = {}

  -- Title (plain text — markdown heading concealment is unreliable and
  -- brackets in titles get eaten by markdown link syntax)
  table.insert(lines, (pr.title or ""))
  table.insert(lines, "")

  -- Status line
  local status = pr.isDraft and "○ Draft" or "● Open"
  table.insert(lines, "**Status:**     " .. status)

  -- Branch
  if pr.baseRefName and pr.headRefName then
    table.insert(lines, "**Branch:**     `" .. pr.baseRefName .. "` ← `" .. pr.headRefName .. "`")
  end

  -- Author
  table.insert(lines, "**Author:**     @" .. (pr.author or ""))

  -- Dates
  if pr.createdAt then
    table.insert(lines, "**Created:**    " .. relative_time(pr.createdAt))
  end
  if pr.updatedAt then
    table.insert(lines, "**Updated:**    " .. relative_time(pr.updatedAt))
  end

  -- Review decision
  if pr.reviewDecision and pr.reviewDecision ~= "" then
    local map = {
      APPROVED = "✓ Approved",
      CHANGES_REQUESTED = "✗ Changes requested",
      REVIEW_REQUIRED = "Review required",
    }
    table.insert(lines, "**Review:**     " .. (map[pr.reviewDecision] or pr.reviewDecision))
  end

  -- Mergeable
  if pr.mergeable and pr.mergeable ~= "" and pr.mergeable ~= "UNKNOWN" then
    local map = { MERGEABLE = "✓ Yes", CONFLICTING = "✗ Conflicting" }
    table.insert(lines, "**Mergeable:**  " .. (map[pr.mergeable] or pr.mergeable))
  end

  -- Changes stats
  local add = pr.additions or 0
  local del = pr.deletions or 0
  local files = pr.changedFiles or 0
  if files > 0 then
    local stat_parts = { tostring(files) .. " files" }
    if add > 0 then table.insert(stat_parts, "`+" .. add .. "`") end
    if del > 0 then table.insert(stat_parts, "`-" .. del .. "`") end
    table.insert(lines, "**Changes:**    " .. table.concat(stat_parts, "  "))
  end

  -- Labels
  if pr.labels and #pr.labels > 0 then
    local names = {}
    for _, l in ipairs(pr.labels) do
      table.insert(names, "`" .. (type(l) == "table" and (l.name or "") or l) .. "`")
    end
    table.insert(lines, "**Labels:**     " .. table.concat(names, "  "))
  end

  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  -- Body (strip \r to avoid ^M characters)
  local body = (pr.body or ""):gsub("\r", "")
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  return lines
end

-- ── List line formatting ────────────────────────────────────────────────────

local function format_pr_line(pr)
  local icon = pr.isDraft and "○" or "●"
  local icon_hl = pr.isDraft and "GitDiffViewerDim" or "GitDiffViewerStatusA"

  local number_str = "#" .. pr.number
  local title = pr.title or ""
  local author_str = "@" .. (pr.author or "")

  local label_str = ""
  if pr.labels and #pr.labels > 0 then
    local names = {}
    for _, l in ipairs(pr.labels) do
      table.insert(names, type(l) == "table" and (l.name or "") or l)
    end
    label_str = table.concat(names, ", ")
  end

  -- Build line: "  ● #15802  Title text  @author  labels"
  local line_parts = {}
  local hls = {}
  local col = 0

  -- Indent
  table.insert(line_parts, "  ")
  col = 2

  -- Icon
  table.insert(line_parts, icon)
  table.insert(hls, { group = icon_hl, col_start = col, col_end = col + #icon })
  col = col + #icon

  -- Space + number
  table.insert(line_parts, " ")
  col = col + 1
  table.insert(line_parts, number_str)
  table.insert(hls, { group = "GitDiffViewerPrNumber", col_start = col, col_end = col + #number_str })
  col = col + #number_str

  -- Gap + title
  table.insert(line_parts, "  ")
  col = col + 2
  table.insert(line_parts, title)
  col = col + #title

  -- Space + author
  table.insert(line_parts, " ")
  col = col + 1
  table.insert(line_parts, author_str)
  table.insert(hls, { group = "GitDiffViewerPrAuthor", col_start = col, col_end = col + #author_str })
  col = col + #author_str

  -- Space + labels
  if #label_str > 0 then
    table.insert(line_parts, " ")
    col = col + 1
    table.insert(line_parts, label_str)
    table.insert(hls, { group = "GitDiffViewerDim", col_start = col, col_end = col + #label_str })
  end

  return table.concat(line_parts), hls
end

-- ── Picker ──────────────────────────────────────────────────────────────────

-- Track the active picker so we can prevent double-opens
local active_picker = nil

local function create_picker()
  -- Close any existing picker before opening a new one
  if active_picker and active_picker.is_valid() then
    active_picker.close()
  end
  -- Layout — start with 50% list width; resized after data arrives
  local total_width = vim.o.columns - 4
  local list_height = vim.o.lines - 6
  local total_visual = list_height + 4
  local start_row = math.floor((vim.o.lines - total_visual) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)
  local list_width = math.floor(total_width * 0.5)
  local preview_width = total_width - list_width - 1

  -- ── Input window (top-left) ─────────────────────────────────────────────
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "git-diff-viewer-pr-picker"
  vim.b[input_buf].completion = false
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    row = start_row + 1,
    col = start_col,
    width = list_width,
    height = 1,
    style = "minimal",
    border = { "╭", "─", "╮", "│", "┤", "─", "├", "│" },
    title = " Open Pull Requests ",
    title_pos = "center",
  })
  vim.wo[input_win].winhl = "Normal:Normal,FloatBorder:Comment"
  vim.wo[input_win].number = false
  vim.wo[input_win].signcolumn = "no"

  -- ── List window (below input) ───────────────────────────────────────────
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "wipe"
  vim.bo[list_buf].buftype = "nofile"
  vim.bo[list_buf].modifiable = false

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor",
    row = start_row + 4,
    col = start_col,
    width = list_width,
    height = list_height,
    style = "minimal",
    border = { "", "", "", "│", "╯", "─", "╰", "│" },
    focusable = false,
  })
  vim.wo[list_win].cursorline = true
  vim.wo[list_win].number = false
  vim.wo[list_win].signcolumn = "no"
  vim.wo[list_win].wrap = false
  vim.wo[list_win].winhl = "Normal:Normal"

  -- ── Preview window (right side) ─────────────────────────────────────────
  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].modifiable = false
  vim.bo[preview_buf].filetype = "markdown"

  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "editor",
    row = start_row + 1,
    col = start_col + list_width + 1,
    width = preview_width,
    height = list_height + 3,
    style = "minimal",
    border = "rounded",
    title = " Preview ",
    title_pos = "center",
    focusable = false,
  })
  vim.wo[preview_win].wrap = true
  vim.wo[preview_win].linebreak = true
  vim.wo[preview_win].number = false
  vim.wo[preview_win].signcolumn = "no"
  vim.wo[preview_win].conceallevel = 2
  vim.wo[preview_win].winhl = "Normal:Normal,FloatBorder:Comment"

  -- ── Loading state ─────────────────────────────────────────────────────
  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, { "  Loading…" })
  vim.bo[list_buf].modifiable = false

  -- ── State ─────────────────────────────────────────────────────────────
  local all_prs = nil -- nil = loading, table = loaded
  local filtered_prs = {}
  local total_count = 0

  -- ── Actions ───────────────────────────────────────────────────────────
  local aug = vim.api.nvim_create_augroup("GitDiffViewerPrPicker", { clear = true })

  local function close()
    active_picker = nil
    vim.api.nvim_clear_autocmds({ group = aug })
    vim.cmd("stopinsert")
    for _, w in ipairs({ preview_win, list_win, input_win }) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
  end

  local function get_filter()
    if not vim.api.nvim_buf_is_valid(input_buf) then return "" end
    return vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ""
  end

  local function update_preview()
    if not vim.api.nvim_win_is_valid(list_win) then return end
    if not vim.api.nvim_buf_is_valid(preview_buf) then return end

    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    local pr = filtered_prs[row]

    local lines = pr and build_preview_lines(pr) or {}
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false

    -- Highlight the title line (first line)
    vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, 1)
    if pr and #lines > 0 then
      vim.api.nvim_buf_add_highlight(preview_buf, ns, "Title", 0, 0, -1)
    end

    -- Update preview window title
    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        title = pr and (" PR #" .. pr.number .. " ") or " Preview ",
        title_pos = "center",
      })
    end

    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })
    end
  end

  local function render_list(filter)
    if all_prs == nil then return end -- still loading
    if not vim.api.nvim_buf_is_valid(list_buf) then return end

    filtered_prs = {}
    for _, pr in ipairs(all_prs) do
      if utils.fuzzy_match(pr._search_str, filter) then
        table.insert(filtered_prs, pr)
      end
    end

    -- Update count in input title
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_set_config(input_win, {
        title = " Open Pull Requests (" .. #filtered_prs .. "/" .. total_count .. ") ",
        title_pos = "center",
      })
    end

    -- Build lines and highlights
    local text_lines = {}
    local all_hls = {}
    for i, pr in ipairs(filtered_prs) do
      local line, hls = format_pr_line(pr)
      table.insert(text_lines, line)
      for _, h in ipairs(hls) do
        h.line = i - 1
        table.insert(all_hls, h)
      end
    end

    if #text_lines == 0 then
      text_lines = { "  No matching PRs" }
    end

    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, text_lines)
    vim.bo[list_buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    for _, h in ipairs(all_hls) do
      vim.api.nvim_buf_add_highlight(list_buf, ns, h.group, h.line, h.col_start, h.col_end)
    end

    -- Move cursor to first item
    if vim.api.nvim_win_is_valid(list_win) and #filtered_prs > 0 then
      vim.api.nvim_win_set_cursor(list_win, { 1, 0 })
    end

    update_preview()
  end

  local function open_selected()
    if not vim.api.nvim_win_is_valid(list_win) then return end
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    local pr = filtered_prs[row]
    if pr and pr.url then
      close()
      vim.ui.open(pr.url)
    end
  end

  local function move_selection(delta)
    if not vim.api.nvim_win_is_valid(list_win) then return end
    if #filtered_prs == 0 then return end
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    local target = math.max(1, math.min(row + delta, #filtered_prs))
    vim.api.nvim_win_set_cursor(list_win, { target, 0 })
    update_preview()
  end

  -- ── Keymaps ───────────────────────────────────────────────────────────
  local function imap(key, fn)
    vim.keymap.set("i", key, fn, { buffer = input_buf, nowait = true })
  end
  local function nmap(key, fn)
    vim.keymap.set("n", key, fn, { buffer = input_buf, nowait = true })
  end

  imap("<CR>",   open_selected)
  imap("<C-c>",  close)
  imap("<Down>", function() move_selection(1) end)
  imap("<Up>",   function() move_selection(-1) end)
  imap("<C-j>",  function() move_selection(1) end)
  imap("<C-k>",  function() move_selection(-1) end)
  imap("<C-n>",  function() move_selection(1) end)
  imap("<C-p>",  function() move_selection(-1) end)

  nmap("<CR>",   open_selected)
  nmap("<Esc>",  close)
  nmap("q",      close)
  nmap("<Down>", function() move_selection(1) end)
  nmap("<Up>",   function() move_selection(-1) end)
  nmap("j",      function() move_selection(1) end)
  nmap("k",      function() move_selection(-1) end)

  -- ── Live filtering ────────────────────────────────────────────────────
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input_buf,
    group = aug,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(list_buf) then return end
        if not vim.api.nvim_buf_is_valid(input_buf) then return end
        render_list(get_filter())
      end)
    end,
  })

  -- Close if any window disappears
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == input_win or closed == list_win or closed == preview_win then
        vim.schedule(close)
      end
    end,
  })

  vim.cmd("startinsert!")

  -- ── Resize helper ─────────────────────────────────────────────────────
  local function resize_layout(new_list_width)
    list_width = new_list_width
    preview_width = total_width - list_width - 1

    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_set_config(input_win, {
        relative = "editor",
        row = start_row + 1,
        col = start_col,
        width = list_width,
      })
    end
    if vim.api.nvim_win_is_valid(list_win) then
      vim.api.nvim_win_set_config(list_win, {
        relative = "editor",
        row = start_row + 4,
        col = start_col,
        width = list_width,
      })
    end
    if vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        relative = "editor",
        row = start_row + 1,
        col = start_col + list_width + 1,
        width = preview_width,
      })
    end
  end

  -- ── Public interface ──────────────────────────────────────────────────

  local function populate(prs)
    all_prs = prs
    total_count = #prs

    -- Compute optimal list width from longest formatted line
    local max_display_w = 0
    for _, pr in ipairs(prs) do
      local line = format_pr_line(pr)
      local w = vim.fn.strdisplaywidth(line)
      if w > max_display_w then max_display_w = w end
    end
    local min_list = 60
    local max_list = math.floor(total_width * 0.65)
    local optimal = math.max(min_list, math.min(max_display_w + 4, max_list))
    resize_layout(optimal)

    render_list(get_filter())
  end

  local function show_message(msg)
    if not vim.api.nvim_buf_is_valid(list_buf) then return end
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, { "  " .. msg })
    vim.bo[list_buf].modifiable = false
  end

  local picker = {
    is_valid = function() return vim.api.nvim_win_is_valid(input_win) end,
    populate = populate,
    show_message = show_message,
    close = close,
  }
  active_picker = picker
  return picker
end

-- ── Entry point ─────────────────────────────────────────────────────────────

function M.open()
  if vim.fn.executable("gh") ~= 1 then
    utils.error("gh CLI not found. Install it from https://cli.github.com")
    return
  end

  local cwd = vim.fn.getcwd()

  -- Open picker immediately with loading state
  local picker = create_picker()

  -- Fetch data asynchronously
  gh.list_open_prs(cwd, function(ok, raw_json, stderr)
    vim.schedule(function()
      if not picker.is_valid() then return end

      if not ok then
        local msg = stderr or "unknown error"
        if msg:find("auth") or msg:find("login") then
          picker.show_message("gh is not authenticated. Run `gh auth login` first.")
        else
          picker.show_message("Error: " .. msg)
        end
        return
      end

      local decode_ok, prs = pcall(vim.json.decode, raw_json)
      if not decode_ok or type(prs) ~= "table" then
        picker.show_message("Failed to parse PR data from gh")
        return
      end

      if #prs == 0 then
        picker.show_message("No open PRs found")
        return
      end

      -- Sort by updatedAt descending (most recent first)
      table.sort(prs, function(a, b)
        return (a.updatedAt or "") > (b.updatedAt or "")
      end)

      -- Normalize and build search strings
      for _, pr in ipairs(prs) do
        if type(pr.author) == "table" then
          pr.author = pr.author.login or ""
        end

        local parts = { "#" .. pr.number, pr.title or "", "@" .. (pr.author or "") }
        if pr.labels then
          for _, l in ipairs(pr.labels) do
            table.insert(parts, type(l) == "table" and (l.name or "") or l)
          end
        end
        pr._search_str = table.concat(parts, " ")
      end

      picker.populate(prs)
    end)
  end)
end

return M
