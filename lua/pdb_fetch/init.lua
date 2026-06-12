-- pdb_fetch.nvim - presentation layer over the pdb_fetch CLI.
-- Every view IS a pdb_fetch invocation; the plugin only resolves what is
-- under the cursor (function/statement/address) and renders the output.

local M = {}
local uv = vim.uv or vim.loop

M.config = {
  keymaps = true, -- vbs/vts (structure), vbf/vtf (function asm), V (stmt peek)
  split = "botright vsplit", -- where view windows open
}

local INDEX = { base = "binaries/rich/base/index.jsonl",
                target = "binaries/rich/target/index.jsonl" }

-- ---------------------------------------------------------------- project --

--- Walk up from the buffer's file to the checkout containing the indexes,
--- so sibling worktrees each query their own binaries/rich.
local function project_root(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr or 0)
  if file == "" then return nil end
  for dir in vim.fs.parents(file) do
    if uv.fs_stat(dir .. "/" .. INDEX.base) then return dir end
  end
end

--- Index `file` fields are relative to <root>/sources/.
local function rel_source(file, root)
  local prefix = root .. "/sources/"
  if file:sub(1, #prefix) == prefix then return file:sub(#prefix + 1) end
end

-- ----------------------------------------------------- function at cursor --

-- {index_path -> {mtime=, files={relfile -> entries}}}
local cache = {}

local function entries_for(root, relfile)
  local idx = root .. "/" .. INDEX.base
  local st = uv.fs_stat(idx)
  if not st then return nil end
  local c = cache[idx]
  if not c or c.mtime ~= st.mtime.sec then
    c = { mtime = st.mtime.sec, files = {} }
    cache[idx] = c
  end
  if c.files[relfile] then return c.files[relfile] end

  local needle = '"file":"' .. relfile .. '"'
  local lines
  if vim.fn.executable("rg") == 1 then
    lines = vim.fn.systemlist({ "rg", "--no-line-number", "-F", needle, idx })
  else -- plain scan fallback; the index is tens of MB, rg is much faster
    lines = {}
    for line in io.lines(idx) do
      if line:find(needle, 1, true) then lines[#lines + 1] = line end
    end
  end
  local entries = {}
  for _, line in ipairs(lines) do
    local ok, e = pcall(vim.json.decode, line)
    if ok then entries[#entries + 1] = e end
  end
  c.files[relfile] = entries
  return entries
end

local function line_span(e)
  local lo, hi = math.huge, 0
  for _, s in ipairs(e.statements or {}) do
    if s.line and s.line > 0 then
      lo, hi = math.min(lo, s.line), math.max(hi, s.line)
    end
  end
  return lo, hi
end

--- The function whose statement lines cover `lnum` (tightest span wins -
--- inlined-into neighbors can overlap).
local function function_at(root, relfile, lnum)
  local best, best_width
  for _, e in ipairs(entries_for(root, relfile) or {}) do
    local lo, hi = line_span(e)
    if lnum >= lo and lnum <= hi then
      local width = hi - lo
      if not best or width < best_width then best, best_width = e, width end
    end
  end
  return best
end

--- The statement starting exactly on `lnum` (first if several).
local function stmt_at(entry, lnum)
  for _, s in ipairs(entry.statements or {}) do
    if s.line == lnum then return s end
  end
end

local function va_of(entry, off)
  return string.format("0x%x", entry.image_base + entry.rva + off)
end

--- Cross-side `--function` selector. Full demangled signatures do NOT pair
--- across the two PDBs (the target spells top-level parameter const, the
--- base does not), but the qualified path matches both. Derive it from the
--- mangled name - identical on both sides; `?fn@inner@outer@@...` is
--- innermost-first. Templates/operators mangle with `?$`/`??` and fall back
--- to the demangled signature (same-side views still work).
local function qualified_name(entry)
  local path = (entry.mangled or ""):match("^%?([%w_@]-)@@")
  if path and path ~= "" then
    local parts = vim.split(path, "@", { plain = true })
    local rev = {}
    for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
    return table.concat(rev, "::")
  end
  return entry.name
end

-- -------------------------------------------------------------- execution --

local function side_args(root, side)
  local args = {}
  if side == "base" or side == "diff" then
    vim.list_extend(args, { "--base-index", INDEX.base })
  end
  if side == "target" or side == "diff" then
    vim.list_extend(args, { "--target-index", INDEX.target })
  end
  if side == "diff" then -- operand-aware diff backend when the objs exist
    if uv.fs_stat(root .. "/binaries/objdiff/base") then
      vim.list_extend(args, { "--objdiff-base-dir", "binaries/objdiff/base",
                              "--objdiff-target-dir", "binaries/objdiff/target" })
    end
  end
  return args
end

-- every invocation is logged (:VostokLog) with the resolved binary path -
-- a stale dev shell shipping an old pdb_fetch is the classic silent killer
-- (an old --address selector re-based VAs as RVAs: wrong function entirely)
M._log = {}
local function log(line)
  table.insert(M._log, os.date("%H:%M:%S ") .. line)
  if #M._log > 200 then table.remove(M._log, 1) end
end

function M.show_log()
  local lines = #M._log > 0 and vim.deepcopy(M._log) or { "(no queries yet)" }
  table.insert(lines, 1, "pdb_fetch binary: " ..
    (vim.fn.exepath("pdb_fetch") ~= "" and vim.fn.exepath("pdb_fetch")
     or "NOT ON PATH"))
  vim.cmd(M.config.split)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

local function run(root, args, cb)
  if vim.fn.executable("pdb_fetch") == 0 then
    return vim.notify("pdb_fetch: not on PATH - launch nvim from the " ..
      "project dev shell (nix develop)", vim.log.levels.ERROR)
  end
  local cmd = vim.list_extend({ "pdb_fetch" }, args)
  log(table.concat(cmd, " ") .. "  [" .. root .. "]")
  vim.system(cmd, { cwd = root, text = true }, function(res)
    vim.schedule(function()
      local out = (res.stdout or "")
      if res.code ~= 0 and (res.stderr or "") ~= "" then
        out = out .. res.stderr
      end
      local lines = vim.split(out, "\n", { trimempty = true })
      if #lines == 0 then lines = { "(pdb_fetch produced no output)" } end
      cb(lines)
    end)
  end)
end

-- -------------------------------------------------------------- rendering --

-- syntax per view: rich asm gets asm highlighting, the asm diff keeps
-- diff's +/- coloring; tables stay plain
local VIEW_FT = { base = "asm", target = "asm", diff = "diff" }

local function fill(buf, lines, ctx, transient)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = VIEW_FT[ctx.view] or ""
  -- splits/peeks: float buffers die with their window, view buffers persist
  -- (survive :split and window close, refresh on the next same query)
  vim.bo[buf].bufhidden = transient and "wipe" or "hide"
  vim.b[buf].pdb_fetch = ctx
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", "<cmd>close<cr>", opts)
  vim.keymap.set("n", "<CR>", function() M.follow() end, opts)
  vim.keymap.set("n", "ga", function() M.follow() end, opts)
  -- V peeks here too: side inferred from the table column / line prefix
  vim.keymap.set("n", "V", function() M.follow() end, opts)
end

--- Peeks show JUST the asm: drop pdb_fetch's `;` meta and signature lines,
--- keep the [0xNN] statement marker and instruction lines.
local function asm_only(lines)
  local asm = {}
  for _, l in ipairs(lines) do
    if l:match("^%[?0[xX]%x") then asm[#asm + 1] = l end
  end
  if #asm > 0 then return asm end
  return lines -- errors/odd output stay verbatim
end

--- The side lives in the float title (BASE/TARGET + address) so it is never
--- ambiguous; pre-composed content (ctx.raw) brings its own title.
local function show_float(lines, ctx)
  if not ctx.raw then
    lines = asm_only(lines)
    ctx.title = (ctx.side or "?"):upper() .. (ctx.addr and (" " .. ctx.addr) or "")
  end
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end
  width = math.min(width + 1, vim.o.columns - 4)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local buf = vim.api.nvim_create_buf(false, true)
  fill(buf, lines, ctx, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0,
    width = width, height = height,
    style = "minimal", border = "single",
    title = ctx.title, title_pos = "left",
  })
  -- a peek dismisses itself: leaving the float closes it (q/<Esc> too)
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>",
    { buffer = buf, nowait = true, silent = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

--- One buffer per (side, view, symbol): rerunning the same query refreshes
--- it in place, different queries coexist - open as many splits as you like.
local function show_split(lines, ctx)
  local sym = (ctx.name or "?"):gsub("[^%w_:~]+", "."):sub(1, 80)
  local name = ("pdbfetch://%s-%s/%s"):format(ctx.side, ctx.view, sym)
  local buf = vim.fn.bufnr("^" .. vim.fn.fnameescape(name) .. "$")
  if buf == -1 then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  fill(buf, lines, ctx)
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then win = w break end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd(M.config.split)
    vim.api.nvim_win_set_buf(0, buf)
  end
  if ctx.search then vim.fn.search(ctx.search) end
end

-- ---------------------------------------------------------- address links --

--- Header-table column at the cursor, for structure-diff side resolution:
--- returns the name of the `|`-separated field the cursor column falls in.
local function column_at(header, col)
  local start = 0
  for field in (header .. "|"):gmatch("([^|]*)|") do
    local stop = start + #field
    if col >= start and col <= stop then return vim.trim(field) end
    start = stop + 1
  end
end

--- Both statements of a structure-diff row, side by side in one float:
--- target asm left, base asm right, sizes from the row's t.sz/b.sz columns.
local function peek_pair(ctx, row, header)
  local fields = {}
  local start = 0
  for field in (header .. "|"):gmatch("([^|]*)|") do
    local value = vim.trim(row:sub(start + 1, start + #field))
    fields[vim.trim(field)] = value
    start = start + #field + 1
  end
  local taddr = (fields["t.addr"] or ""):match("^0x%x+$")
  local baddr = (fields["b.addr"] or ""):match("^0x%x+$")
  if not (taddr and baddr) then return false end -- one-sided row: single peek

  local function fetch(side, addr, cb)
    local a = side_args(ctx.root, side)
    vim.list_extend(a, { "--address", addr,
                         "--view", side == "target" and "target" or "base" })
    run(ctx.root, a, cb)
  end
  fetch("target", taddr, function(tl)
    fetch("base", baddr, function(bl)
      tl, bl = asm_only(tl), asm_only(bl)
      local width = 0
      for _, l in ipairs(tl) do width = math.max(width, #l) end
      local out = {}
      for i = 1, math.max(#tl, #bl) do
        local l, r = tl[i] or "", bl[i] or ""
        out[#out + 1] = l .. string.rep(" ", width - #l + 2) .. "| " .. r
      end
      show_float(out, {
        root = ctx.root, side = "diff", view = "pair", raw = true,
        title = ("TARGET %s %s | BASE %s %s"):format(
          taddr, fields["t.sz"] or "", baddr, fields["b.sz"] or ""),
      })
    end)
  end)
  return true
end

--- Follow the address/offset under the cursor inside a plugin view.
function M.follow()
  local ctx = vim.b.pdb_fetch
  if not ctx then return end

  -- a single statement's asm alone is rarely what you want from a paired
  -- structure-diff row: peek BOTH sides side by side when the row has both
  -- addresses (works from anywhere on the row, no address under cursor needed)
  local sd_header
  if ctx.view == "structure-diff" then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, 20, false)) do
      if l:find("|t.addr", 1, true) then sd_header = l break end
    end
    if sd_header
        and peek_pair(ctx, vim.api.nvim_get_current_line(), sd_header) then
      return
    end
  end

  local word = vim.fn.expand("<cword>")
  local hex = word:match("^0[xX]%x+$") and word
  if not hex then
    return vim.notify("pdb_fetch: no address under cursor", vim.log.levels.INFO)
  end

  local side, selector = ctx.side, nil
  if ctx.view == "structure-diff" then
    local field = sd_header and column_at(sd_header, vim.fn.col(".") - 1) or ""
    side = field:find("^t%.") and "target" or "base"
    selector = { "--address", hex }
  elseif ctx.view == "diff" then
    -- side comes from the -/+ line prefix; numbers are function offsets
    local prefix = vim.api.nvim_get_current_line():sub(1, 1)
    side = (prefix == "+") and "target" or "base"
    selector = { "--function", ctx.name, "--offset", hex }
  elseif ctx.view == "structure" then
    selector = { "--address", hex } -- the address column, view's own side
  else -- rich asm: [0xNN] statement heads / instruction offsets
    selector = { "--function", ctx.name, "--offset", hex }
  end

  local view = (side == "target") and "target" or "base"
  local args = side_args(ctx.root, side)
  vim.list_extend(args, selector)
  vim.list_extend(args, { "--view", view })
  run(ctx.root, args, function(lines)
    show_float(lines, { root = ctx.root, side = side, view = view,
                        name = ctx.name, addr = hex })
  end)
end

-- ------------------------------------------------------------ entry point --

local VIEW_FLAG = {
  base = { structure = "structure", asm = "base" },
  target = { structure = "structure", asm = "target" },
  diff = { structure = "structure-diff", asm = "diff" },
}

--- :Vostok {base|target|diff} {stmt|asm|structure} from a source buffer.
function M.view(side, kind)
  local root = project_root(0)
  if not root then
    return vim.notify("pdb_fetch: no binaries/rich above this file",
      vim.log.levels.ERROR)
  end
  local relfile = rel_source(vim.api.nvim_buf_get_name(0), root)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cword = vim.fn.expand("<cword>")
  local addr = cword:match("^0[xX]%x+$") and cword

  -- All cursor->function/statement mapping keys on the LAST BUILD's line
  -- tables. Edits shift lines until the next rebuild - detect and SAY it
  -- rather than resolve silently wrong. (Addresses never go stale: with the
  -- cursor on a 0x... the index is bypassed entirely.)
  local stale
  if vim.bo.modified then
    stale = "unsaved buffer edits"
  else
    local src = uv.fs_stat(vim.api.nvim_buf_get_name(0))
    local idx = uv.fs_stat(root .. "/" .. INDEX.base)
    if src and idx and src.mtime.sec > idx.mtime.sec then
      stale = "source saved after the index was built"
    end
  end

  -- an address under the cursor (carcass comments carry target VAs) selects
  -- the function for target/diff views without needing the index
  local selector, entry
  if addr and side ~= "base" then
    selector = { "--va", addr }
  else
    if not relfile then
      return vim.notify("pdb_fetch: buffer is not under <root>/sources/",
        vim.log.levels.ERROR)
    end
    entry = function_at(root, relfile, lnum)
    if not entry then
      return vim.notify("pdb_fetch: no function at this line in the base index",
        vim.log.levels.WARN)
    end
    selector = { "--function", qualified_name(entry) }
  end
  local name = entry and entry.name or addr

  local function show(args, view, opts)
    local a = side_args(root, side)
    vim.list_extend(a, args)
    run(root, a, function(lines)
      -- peeks (floats) stay clean; the warning only heads full views
      if stale and not addr and not (opts and opts.float) then
        table.insert(lines, 1,
          "; STALE LINES: " .. stale .. " - cursor mapping may be off; rebuild,")
        table.insert(lines, 2,
          ";              or navigate by address (cursor on a 0x...).")
      end
      local ctx = { root = root, side = side, view = view, name = name,
                    title = side .. " " .. view,
                    addr = opts and opts.addr,
                    search = opts and opts.search }
      if opts and opts.float then show_float(lines, ctx)
      else show_split(lines, ctx) end
    end)
  end

  if kind ~= "stmt" then
    local view = VIEW_FLAG[side][kind]
    return show(vim.list_extend(vim.deepcopy(selector), { "--view", view }), view)
  end

  -- stmt: needs the statement at the cursor line, hence the index entry
  if not entry then
    return vim.notify("pdb_fetch: stmt views need the cursor inside a function",
      vim.log.levels.WARN)
  end
  local stmt = stmt_at(entry, lnum)
  if not stmt then
    return vim.notify("pdb_fetch: no statement starts on this line",
      vim.log.levels.WARN)
  end

  if side == "base" then
    local va = va_of(entry, stmt.off)
    show({ "--address", va, "--view", "base" }, "base",
      { float = true, addr = va })
  elseif side == "diff" then
    -- the diff view ignores statement selectors: open it whole and land on
    -- the statement's base offset
    show({ "--function", qualified_name(entry), "--view", "diff" }, "diff",
      { search = ("^[-+ ] ?0x0*%x:"):format(stmt.off) })
  else
    -- target: the two sources disagree on absolute line numbers (the
    -- target file predates ours), but matched functions agree on line
    -- DELTAS from each side's first statement - the same key the
    -- structure-diff's t.ln/b.ln columns use. Pair through that.
    local base_first
    for _, s in ipairs(entry.statements) do
      if s.line and s.line > 0 then base_first = s.line break end
    end
    local want = stmt.line - base_first
    local a = side_args(root, "target")
    vim.list_extend(a, { "--function", qualified_name(entry), "--view", "structure" })
    run(root, a, function(lines)
      local taddr, t_first
      for _, l in ipairs(lines) do
        local address, line = l:match("^(0x%x+)|[^|]*|[^|]*|(%d+)")
        if address then
          t_first = t_first or tonumber(line)
          if tonumber(line) - t_first == want then taddr = address break end
        end
      end
      if not taddr then
        return vim.notify(
          "pdb_fetch: no paired target statement for line " .. stmt.line,
          vim.log.levels.WARN)
      end
      local b = side_args(root, "target")
      vim.list_extend(b, { "--address", taddr, "--view", "target" })
      run(root, b, function(out)
        show_float(out, { root = root, side = "target", view = "target",
                          name = name, addr = taddr })
      end)
    end)
  end
end

--- vd: side-by-side function asm - TARGET left, BASE right (the objdiff
--- look), scrollbound. Buffers come from the same naming scheme as the
--- other views, so rerunning refreshes in place.
function M.view_pair()
  local root = project_root(0)
  if not root then
    return vim.notify("pdb_fetch: no binaries/rich above this file",
      vim.log.levels.ERROR)
  end
  local relfile = rel_source(vim.api.nvim_buf_get_name(0), root)
  if not relfile then
    return vim.notify("pdb_fetch: buffer is not under <root>/sources/",
      vim.log.levels.ERROR)
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entry = function_at(root, relfile, lnum)
  if not entry then
    return vim.notify("pdb_fetch: no function at this line in the base index",
      vim.log.levels.WARN)
  end
  local qn = qualified_name(entry)

  local function fetch(side, view, cb)
    local a = side_args(root, side)
    vim.list_extend(a, { "--function", qn, "--view", view })
    run(root, a, cb)
  end

  fetch("target", "target", function(tlines)
    fetch("base", "base", function(blines)
      show_split(tlines, { root = root, side = "target", view = "target",
                           name = entry.name, title = "target" })
      local twin = vim.api.nvim_get_current_win()
      vim.wo[twin].scrollbind = true
      vim.cmd("rightbelow vsplit")
      local bbuf_lines = blines
      -- render base beside target through the same per-view buffer scheme
      local sym = (entry.name or "?"):gsub("[^%w_:~]+", "."):sub(1, 80)
      local bname = ("pdbfetch://base-base/%s"):format(sym)
      local bbuf = vim.fn.bufnr("^" .. vim.fn.fnameescape(bname) .. "$")
      if bbuf == -1 then
        bbuf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(bbuf, bname)
      end
      fill(bbuf, bbuf_lines, { root = root, side = "base", view = "base",
                               name = entry.name })
      vim.api.nvim_win_set_buf(0, bbuf)
      vim.wo[0].scrollbind = true
      vim.cmd("syncbind")
    end)
  end)
end

--- The V peek. Inside plugin views the side comes from the table column /
--- diff prefix (follow). In source buffers, carcass stubs annotate each
--- statement with its TARGET VA (`// <0xVA>|...`) - peek that statement's
--- target asm; lines without an annotation peek the base statement.
function M.peek()
  if vim.b.pdb_fetch then return M.follow() end
  local tva = vim.api.nvim_get_current_line():match("<(0[xX]%x+)>")
  if not tva then return M.view("base", "stmt") end
  local root = project_root(0)
  if not root then
    return vim.notify("pdb_fetch: no binaries/rich above this file",
      vim.log.levels.ERROR)
  end
  local a = side_args(root, "target")
  vim.list_extend(a, { "--address", tva, "--view", "target" })
  run(root, a, function(out)
    show_float(out, { root = root, side = "target", view = "target",
                      name = tva, addr = tva })
  end)
end

--- Run the project's rebuild (build + regen of every index the views read)
--- in a terminal split at the project root. Extra args go to rebuild.py
--- (e.g. :VostokRebuild logging builds one project first).
function M.rebuild(args)
  local root = project_root(0)
  if not root then
    return vim.notify("pdb_fetch: no binaries/rich above this file",
      vim.log.levels.ERROR)
  end
  local cmd = { "python3", "scripts/rebuild.py" }
  vim.list_extend(cmd, args or {})
  vim.cmd(M.config.split)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.fn.termopen(cmd, {
    cwd = root,
    on_exit = function(_, code)
      vim.schedule(function()
        vim.notify(code == 0 and "rebuild: done - views are fresh"
          or ("rebuild: FAILED (exit " .. code .. ")"),
          code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
    end,
  })
end

local warned_missing
--- Startup check, called when a c/cpp buffer attaches: warn (once) if the
--- buffer belongs to a project but the pdb_fetch CLI is not on PATH - the
--- usual cause is nvim launched outside the project dev shell. Outside a
--- project the plugin is inert and stays silent.
function M.check(buf)
  if warned_missing or not project_root(buf) then return end
  if vim.fn.executable("pdb_fetch") == 0 then
    warned_missing = true
    vim.notify(
      "pdb_fetch.nvim: `pdb_fetch` not on PATH - launch nvim from the " ..
      "project dev shell (nix develop) for :Vostok views to work",
      vim.log.levels.WARN)
  end
end

-- completion for :Vostok
function M.complete(_, cmdline)
  local side = cmdline:match("Vostok%s+(%S+)%s+%S*$")
  if side then return { "stmt", "asm", "structure" } end
  return { "base", "target", "diff" }
end

function M.attach_keymaps(buf)
  -- sushi doesn't use visual mode: plain v-prefixed chords, and V itself
  -- peeks the current statement's asm (base in source; in plugin views the
  -- side comes from the table column / diff line prefix).
  local maps = {
    vbs = { "base", "structure" },
    vts = { "target", "structure" },
    vds = { "diff", "structure" },
    -- f (function) and a (asm) both work for the asm views
    vbf = { "base", "asm" },
    vtf = { "target", "asm" },
    vdf = { "diff", "asm" },
    vba = { "base", "asm" },
    vta = { "target", "asm" },
    vda = { "diff", "asm" },
  }
  for lhs, sv in pairs(maps) do
    vim.keymap.set("n", lhs, function() M.view(sv[1], sv[2]) end,
      { buffer = buf, silent = true,
        desc = ("pdb_fetch: %s %s"):format(sv[1], sv[2]) })
  end
  vim.keymap.set("n", "V", function() M.peek() end,
    { buffer = buf, silent = true, desc = "pdb_fetch: statement asm peek" })
  vim.keymap.set("n", "vo", function() M.view_pair() end,
    { buffer = buf, silent = true,
      desc = "pdb_fetch: target|base asm side by side (objdiff look)" })
end

return M
