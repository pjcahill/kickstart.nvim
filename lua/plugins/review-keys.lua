vim.keymap.set("n", "<leader>rs", function() require("review").start() end, { desc = "Start review session" })
vim.keymap.set("n", "<leader>rn", function() require("review").next_file() end, { desc = "Next file in review" })
vim.keymap.set("n", "<leader>rp", function() require("review").prev_file() end, { desc = "Previous file in review" })
vim.keymap.set("n", "<leader>rl", function() require("review").pick() end, { desc = "Review list (Telescope)" })
vim.keymap.set("v", "<leader>cc", ":'<,'>Claude<CR>", { desc = "Send selection to Claude", silent = true })

vim.api.nvim_create_user_command("Claude", function(opts)
  require("review").send_to_claude(opts)
end, { range = true })
