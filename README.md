# pdb_fetch.nvim

Neovim frontend for [`pdb_fetch`](https://github.com/srp-survarium/vostok-pdb-parser):
navigate from the C++ you are editing to the asm / statement structure /
diff of the function (or single statement) under the cursor, in projects
that binary-match against an original PDB.

The plugin is presentation only - every view IS a `pdb_fetch` invocation
(async, rendered into scratch buffers). No plugin-side state, nothing to go
stale; target lookups key on the VA, the one thing that never moves.

## Interface

One command, two arguments, tab-completable:

    :Vostok {base|target|diff} {stmt|asm|structure}

|            | `stmt` (one statement)            | `asm` (function, rich)  | `structure`     |
|------------|-----------------------------------|-------------------------|-----------------|
| **base**   | asm of the statement at cursor    | rich asm                | statement table |
| **target** | the PAIRED statement's asm        | rich asm                | statement table |
| **diff**   | asm diff for the statement        | asm diff                | structure diff  |

Buffer-local keymaps: `<leader>v` + side/view chord -
`bs/ba/bt`, `ts/ta/tt`, `ds/da/dt` ("t" = sTructure).

- Function/statement at cursor resolve through the project's base rich index
  (PDB line tables); a `0x<addr>` under the cursor wins over position.
- In every plugin view, addresses are links: `<CR>` jumps to that statement's
  asm on the address's own side; `q` closes; a view stack gives back-nav.
- `stmt` views float; `asm`/`structure`/`diff` open a reusable scratch split.

The project root is resolved from the EDITED BUFFER's path (walk up to
`binaries/rich/`), so sibling git worktrees each query their own indexes.

## Requirements

`pdb_fetch` on PATH (the consuming project's dev shell provides it) and a
generated `binaries/rich/{base,target}` index pair.

## Status

Interface agreed; implementation pending.
