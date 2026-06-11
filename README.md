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

Buffer-local keymaps (no visual mode here):

    vbs / vts / vds   base / target structure, structure diff
    vbf / vtf / vdf   base / target function asm, asm diff
    V                 statement asm peek - base in source buffers; inside
                      plugin tables the side comes from the column under
                      the cursor (t.addr vs b.addr) or the diff line prefix

`:Vostok diff stmt` (the diff opened at the statement) has no binding.

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

## Install

lazy.nvim:

    { "srp-survarium/pdb_fetch.nvim" }

Run nvim where `pdb_fetch` is on PATH (the project dev shell). The first
use in a buffer greps the base index for that file's functions (rg if
available) and caches it against the index mtime.

## Rebuilding without leaving the editor

`:VostokRebuild [target]` runs the project's `scripts/rebuild.py` in a
terminal split at the buffer's project root (build + regen of everything the
views read) and notifies on completion. The views' index cache invalidates by
mtime, so the next query reads fresh data automatically.

## Line numbers go stale - addresses don't

Everything cursor-based maps through the LAST BUILD's PDB line tables: edit a
file and every resolution below the edit shifts until the next rebuild. The
plugin detects this (unsaved buffer edits, or source newer than the index)
and prefixes views with a `; STALE LINES:` warning instead of resolving
silently wrong. When in doubt, navigate by address - a `0x...` under the
cursor bypasses line mapping entirely, and target VAs never move.

## Pairing notes

- Cross-side function selection uses the qualified path derived from the
  mangled name: full demangled signatures do NOT pair (the target PDB spells
  top-level parameter const, the base does not).
- `target stmt` pairs statements by line DELTA from each side's first
  statement (absolute line numbers differ between the two sources) - the
  same key the structure-diff's `t.ln/b.ln` columns use.
