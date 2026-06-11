if vim.g.loaded_pdb_fetch then return end
vim.g.loaded_pdb_fetch = true

vim.api.nvim_create_user_command("Vostok", function(opts)
  local side, kind = opts.fargs[1], opts.fargs[2]
  local ok_side = side == "base" or side == "target" or side == "diff"
  local ok_kind = kind == "stmt" or kind == "asm" or kind == "structure"
  if not (ok_side and ok_kind) then
    return vim.notify("usage: :Vostok {base|target|diff} {stmt|asm|structure}",
      vim.log.levels.ERROR)
  end
  require("pdb_fetch").view(side, kind)
end, {
  nargs = "+",
  complete = function(arglead, cmdline)
    return vim.tbl_filter(function(c) return vim.startswith(c, arglead) end,
      require("pdb_fetch").complete(arglead, cmdline))
  end,
  desc = "pdb_fetch views for the function/statement at cursor",
})

vim.api.nvim_create_user_command("VostokRebuild", function(opts)
  require("pdb_fetch").rebuild(opts.fargs)
end, { nargs = "*", desc = "run scripts/rebuild.py at the project root" })

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp" },
  group = vim.api.nvim_create_augroup("pdb_fetch_keymaps", { clear = true }),
  callback = function(ev)
    local pf = require("pdb_fetch")
    pf.check(ev.buf)
    if pf.config.keymaps then
      pf.attach_keymaps(ev.buf)
    end
  end,
})
