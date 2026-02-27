-- gh.lua — Async GitHub CLI wrapper
--
-- Uses vim.system() with on_exit callback (same pattern as git.lua).
-- IMPORTANT: on_exit fires on the libuv thread, not the Neovim main thread.
-- Always wrap Neovim API calls inside vim.schedule() in the callback.

local M = {}

-- List open pull requests with full metadata.
-- callback(ok, raw_json, stderr) — called on libuv thread, use vim.schedule() inside
function M.list_open_prs(cwd, callback)
  vim.system({
    "gh", "pr", "list",
    "--state", "open",
    "--json", "number,title,author,state,labels,body,updatedAt,createdAt,headRefName,baseRefName,url,isDraft,additions,deletions,changedFiles,reviewDecision,mergeable",
    "--limit", "100",
  }, {
    cwd = cwd,
    text = true,
  }, function(result)
    callback(result.code == 0, result.stdout or "", result.stderr or "")
  end)
end

return M
