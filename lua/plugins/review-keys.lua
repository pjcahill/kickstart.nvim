vim.keymap.set("n", "<leader>rs", function() require("review").start() end, { desc = "Start review" })
vim.keymap.set("n", "<leader>rq", function() require("review").stop() end, { desc = "Quit review" })
vim.keymap.set("n", "<leader>rl", function() require("review").pick() end, { desc = "Review list (Telescope)" })
vim.keymap.set("n", "<leader>hs", function() require("review").stage_and_advance() end, { desc = "Stage hunk → next" })
vim.keymap.set("n", "<leader>hS", function()
  local gs = require("gitsigns")
  local hunks = gs.get_hunks()
  if not hunks or #hunks == 0 then
    local file = vim.fn.expand("%:p")
    if file ~= "" then
      vim.fn.system({ "git", "add", file })
    end
  else
    gs.stage_buffer()
  end
end, { desc = "Stage buffer/file" })

vim.keymap.set("v", "<leader>cc", ":'<,'>Claude<CR>", { desc = "Send selection to Claude", silent = true })

vim.api.nvim_create_user_command("Claude", function(opts)
  require("review").send_to_claude(opts)
end, { range = true })
