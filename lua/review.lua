local M = {}

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

  vim.g.review_queue = files
  vim.g.review_index = 1
  M.open_current()
end

function M.open_current()
  local files = vim.g.review_queue
  local idx = vim.g.review_index

  if not files or not idx or idx > #files then
    vim.notify("Review complete ✓", vim.log.levels.INFO)
    return
  end

  -- Collapse to a single window, clearing any gitsigns diff splits
  vim.cmd("only")
  vim.cmd("diffoff")

  vim.notify(string.format("[%d/%d] %s", idx, #files, files[idx]), vim.log.levels.INFO)
  vim.cmd("edit " .. vim.fn.fnameescape(files[idx]))
  vim.cmd("Gitsigns diffthis")
end

function M.next_file()
  local idx = vim.g.review_index or 1
  vim.g.review_index = idx + 1
  M.open_current()
end

function M.prev_file()
  local idx = vim.g.review_index or 1
  vim.g.review_index = math.max(1, idx - 1)
  M.open_current()
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
        M.open_current()
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
