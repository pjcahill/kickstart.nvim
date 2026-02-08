local M = {}

local function has_unstaged_changes()
  local status = vim.fn.system("git status --porcelain")
  for line in status:gmatch("[^\n]+") do
    local y = line:sub(2, 2)
    if y ~= " " then return true end
  end
  return false
end

-- Navigate to a specific file in diffview by path, with focus on the diff buffer
function M.goto_file(path)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return end

  local view = lib.get_current_view()
  if not view then return end

  -- set_file_by_path(path, focus, highlight)
  -- focus=true moves cursor to the diff panel, highlight=true updates the file panel
  view:set_file_by_path(path, true, true)
end

function M.start()
  local handle = io.popen("review-queue")
  if not handle then
    vim.notify("Failed to run review-queue", vim.log.levels.ERROR)
    return
  end
  local output = handle:read("*a")
  handle:close()

  local files = {}
  for line in output:gmatch("[^\n]+") do
    table.insert(files, line)
  end

  if #files == 0 then
    vim.notify("Nothing to review", vim.log.levels.INFO)
    return
  end

  if not has_unstaged_changes() then
    vim.ui.select({ "Open Terminal to Commit", "Open Review Session", "Back" }, {
      prompt = "All files already staged",
    }, function(choice)
      if choice == "Open Terminal to Commit" then
        vim.fn.termopen("git status && exec $SHELL")
        vim.cmd("startinsert")
      elseif choice == "Open Review Session" then
        vim.g.review_queue = files
        vim.g.review_index = 1
        vim.g.review_active = true
        vim.cmd("DiffviewOpen")
        vim.defer_fn(function()
          M.goto_file(files[1])
        end, 300)
      end
    end)
    return
  end

  vim.g.review_queue = files
  vim.g.review_index = 0
  vim.g.review_active = true
  vim.cmd("DiffviewOpen")
  vim.defer_fn(function()
    M.advance()
  end, 300)
  vim.notify(string.format("Review: %d files", #files), vim.log.levels.INFO)
end

local function file_needs_review(path)
  local status = vim.fn.system("git status --porcelain -- " .. vim.fn.shellescape(path))
  for line in status:gmatch("[^\n]+") do
    local y = line:sub(2, 2)
    if y ~= " " then return true end
  end
  return false
end

function M.advance()
  local files = vim.g.review_queue
  local idx = (vim.g.review_index or 0)

  -- Skip already-staged files
  repeat
    idx = idx + 1
    if not files or idx > #files then
      if not has_unstaged_changes() then
        vim.ui.select({ "Open Terminal to Commit", "Continue Review", "Back" }, {
          prompt = "All files staged",
        }, function(choice)
          if choice == "Open Terminal to Commit" then
            M.stop()
            vim.fn.termopen("git status && exec $SHELL")
            vim.cmd("startinsert")
          elseif choice == "Back" then
            M.stop()
          end
        end)
      else
        vim.notify(string.format("End of review queue (%d files)", #files), vim.log.levels.INFO)
      end
      return
    end
  until file_needs_review(files[idx])

  vim.g.review_index = idx
  M.goto_file(files[idx])
end

function M.stop()
  vim.cmd("DiffviewClose")
  vim.g.review_active = false
  vim.g.review_queue = nil
  vim.g.review_index = nil
end

function M.stage_and_advance()
  -- If in diffview file panel, use diffview's own staging
  if vim.bo.filetype == "DiffviewFiles" then
    local ok, dv_actions = pcall(require, "diffview.actions")
    if ok then
      dv_actions.toggle_stage_entry()
      vim.defer_fn(function()
        M.advance()
      end, 100)
    end
    return
  end

  local gs = require("gitsigns")
  local hunks_before = gs.get_hunks()

  if not hunks_before or #hunks_before == 0 then
    -- No gitsigns hunks — file is likely untracked, fall back to git add
    local file = vim.fn.expand("%:p")
    if file ~= "" then
      vim.fn.system({ "git", "add", file })
    end
  else
    gs.stage_hunk()
  end

  vim.defer_fn(function()
    local hunks = gs.get_hunks()
    if not hunks or #hunks == 0 then
      M.advance()
    else
      gs.nav_hunk("next", { wrap = false })
    end
  end, 100)
end

function M.pick()
  local files = vim.g.review_queue
  if not files or #files == 0 then
    vim.notify("No review session active", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values

  pickers.new({}, {
    prompt_title = "Review Queue",
    finder = finders.new_table({
      results = files,
      entry_maker = function(entry)
        local idx
        for i, f in ipairs(files) do
          if f == entry then idx = i; break end
        end
        return {
          value = entry,
          display = string.format("[%d/%d] %s", idx, #files, entry),
          ordinal = entry,
          index = idx,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = conf.file_previewer({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        vim.g.review_index = selection.index
        M.goto_file(selection.value)
      end)
      return true
    end,
  }):find()
end

function M.send_to_claude(opts)
  local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
  local filepath = vim.fn.expand("%:p")
  local code = table.concat(lines, "\n")

  local handle = io.popen(
    "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}' | grep -E '[0-9]+\\.[0-9]+\\.[0-9]+'"
  )
  if not handle then
    vim.notify("Failed to query tmux panes", vim.log.levels.WARN)
    return
  end
  local output = handle:read("*a")
  handle:close()

  local panes = {}
  for line in output:gmatch("[^\n]+") do
    table.insert(panes, line)
  end

  if #panes == 0 then
    vim.notify("No Claude Code tmux panes found", vim.log.levels.WARN)
    return
  end

  local function send(pane_line, instruction)
    local target = pane_line:match("^(%S+)")
    local ext = filepath:match("%.(%w+)$") or ""
    local prompt = string.format("File: %s (lines %d-%d)\n```%s\n%s\n```\n\n%s", filepath, opts.line1, opts.line2, ext, code, instruction or "")

    local tmp = "/tmp/claude-review-prompt.md"
    local f = io.open(tmp, "w")
    if f then
      f:write(prompt)
      f:close()
    end

    os.execute(string.format("tmux load-buffer %s", tmp))
    os.execute(string.format("tmux paste-buffer -t %s", target))
    os.execute(string.format("tmux send-keys -t %s Enter", target))
  end

  vim.ui.input({ prompt = "Instruction: " }, function(instruction)
    if instruction == nil then
      return
    end

    if #panes == 1 then
      send(panes[1], instruction)
    else
      vim.ui.select(panes, { prompt = "Select Claude pane:" }, function(choice)
        if choice then
          send(choice, instruction)
        end
      end)
    end
  end)
end

return M
