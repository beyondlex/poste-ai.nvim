# poste-ai.nvim

Generic AI chat layer for the Poste plugin family — a minimal chat sidebar
(streaming, markdown, sessions, @mentions) that satellite plugins extend with
domain **contexts**. Think a much smaller avante.nvim.

## Key Facts

- All Lua code lives under `lua/poste-ai/`
- **Zero dependencies**: no poste.nvim requirement, no Rust binary. Only
  Neovim >= 0.10 and `curl` (streaming via `curl -N` + the Lua SSE parser)
- `plugin/poste-ai.lua` guards with `vim.g.loaded_poste_ai` and calls
  `require("poste-ai").setup()`
- `lua/poste-ai/context_api.lua` is THE extension point: siblings call
  `register_context(id, spec)`. Nothing domain-specific may live in this repo
- API keys come from environment variables only (`provider.api_key_env`);
  never read them from config files, never log or echo them
- Streaming state machine: `chat/stream.lua` owns `busy`/seq guards. Every
  early-return and error path must clear `busy` — a stuck busy flag wedges
  the whole plugin
- User-facing docs live in the docs site: `../doc-poste/src/content/docs/poste-ai/`

## File Index

| File | Role |
|------|------|
| `init.lua` | `setup(opts)`, re-exports `register_context` / `chat` / `send` / `cancel` |
| `config.lua` | providers / request / chat layout / keymaps; `get_keymap(section, action, default)`, `false` disables |
| `state.lua` | cross-cutting flags (active context, origin buffer) |
| `context_api.lua` | context contract: `system_prompt`, `mention.{match,complete,resolve}`, `codeblock.{langs,confirm,execute}` |
| `provider/sse.lua` | pure-function SSE line parser (feed/flush, no I/O) — primary test target |
| `provider/openai.lua` | OpenAI-compatible streaming adapter over `curl -N` + `jobstart` |
| `provider/registry.lua` | adapter registry (require paths or adapter tables, keyed by `protocol`) |
| `chat/window.lua` | two-pane sidebar: `poste://chat` + `poste://chat_input`, all keymaps |
| `chat/conversation.lua` | conversation buffer composition + render extmarks; owns message list and code-block lookup |
| `chat/render.lua` | pure markdown → extmark specs (fences/headings/lists/quotes/inline code) |
| `chat/stream.lua` | send pipeline: mentions → context blocks → provider stream → throttled flush; busy/cancel/follow |
| `chat/session.lua` | multi-session persistence under `stdpath("data")/poste-ai/sessions/` |
| `chat/mention.lua` | @token parsing (context matchers first, file fallback), completion, `resolve_all` aggregation |
| `chat/actions.lua` | code-block actions: execute via context, yank, append-to-origin, jump |
| `commands.lua` / `health.lua` | `:PosteAI*` commands, `:checkhealth poste-ai` |

## Naming Conventions

- `poste-ai` = the plugin: module paths (`require("poste-ai...")`), user commands (`:PosteAI*`)
- `poste_ai` / `PosteAi` = identifiers: namespaces (`poste_ai_chat_render`), augroups
  (`PosteAIChatWindow`, `PosteAISetup`), highlight groups (`PosteAi*`), filetypes
  (`poste_ai_chat`, `poste_ai_input` — programmatic only, no ftdetect)
- Scratch buffer names follow the family scheme: `poste://chat`, `poste://chat_input`

## Relationship with ../poste-db.nvim

**Inverted optional dependency — poste-ai is the dependency-free base.**

```
poste.nvim (shared infra + Rust CLI)      poste-ai.nvim (this repo, zero deps)
        ↑ hard dep                                ↑ optional dep (pcall)
        └────────────────── poste-db.nvim ────────┘
```

- **Direction**: poste-db optionally requires poste-ai — never the reverse.
  This repo must not `require("poste-db...")`, must not contain SQL/schema
  logic, and must not mention connections.toml. Domain knowledge lives in the
  satellite's context, full stop
- **Integration code lives on the poste-db side**: `lua/poste-db/ai/`
  (`init.lua` registers the `db` context; `mentions.lua` handles
  `@conn/db[/table]`; `system_prompt.lua` injects plugin knowledge;
  `actions.lua` executes ```sql blocks through poste-db's executor into the
  dataset view). It `pcall(require, "poste-ai")` in `setup()` and retries on
  `:PosteDbChat`, so both install orders work
- **Contract coupling**: the context contract in `context_api.lua` is a
  cross-repo API. Changing its shape requires updating `lua/poste-db/ai/` in
  the same change set and running both test suites
- **Tests reach across**: poste-db's `tests/minimal_init.lua` appends
  `../poste-ai.nvim` to rtp when present (registration specs are conditional
  on it), and poste-db's CI checks this repo out as a sibling. Keep sibling
  layout `<repo>` + `../poste-ai.nvim` intact

## Neovim Plugin Development Conventions

### Code style

- 2-space indent, double quotes, Unix LF (`.stylua.toml`, `.editorconfig`);
  luacheck must stay at 0 warnings (`allow_defined_top`, long lines OK)
- Module shape: `--- docstring` header, `local M = {}`, `M._test = {...}` hook
  for internals, `return M`; forward-declare locals when a function defined
  later references them (`local parser` in provider/openai.lua)
- Lazy `require(...)` inside function bodies for optional/cyclic deps;
  `pcall(require, ...)` for anything optional

### Buffers & windows

- Scratch buffers: `nvim_create_buf(false, true)` + `nofile` +
  `bufhidden=hide` + `swapfile=false`; create once and reuse across
  open/close cycles (window.lua pattern)
- Always `nvim_buf_is_valid` / `nvim_win_is_valid` before use — handles go
  stale; save and restore `modifiable` around programmatic writes
- Rendering philosophy here: **buffer content is the raw source, styling is
  extmarks only** — copy stays exact and streaming never rewrites lines
  (no flicker by construction). Keep this invariant

### Keymaps & commands

- All keymaps through `config.get_keymap(section, action, default)`, applied
  buffer-locally, `silent`, with a `"PosteAI: ..."` desc; `false` disables
- Commands registered with `{ desc = ... }`; notify via
  `vim.notify(..., level, { title = "PosteAI" })`

### Async & jobs

- Callback style + `vim.schedule` to re-enter the main loop; wrap callbacks
  and `vim.json.decode` in `pcall`
- Guard stale async results with a monotonically increasing seq/epoch
  (stream.lua `st.seq`); drop callbacks from older generations
- Cancel paths: `jobstop` the job, mark cancelled, and let `on_exit` finalize
  — never finalize twice (single `finished` flag)

### API pitfalls (each one bit us already)

- `vim.defer_fn` returns a **uv timer object**. `pcall(vim.fn.timer_stop, t)`
  errors converting it and spams `E5101` into the message system even under
  pcall. Stop it natively: `if not t:is_closing() then t:stop() t:close() end`
- `vim.fn.chanclose(job_id)` with no stream argument closes **all** pipes
  including stdout → curl dies with EPIPE (exit 23) mid-stream. Close stdin
  only: `chanclose(id, "stdin")`
- Lua patterns have no alternation (`|` doesn't work) — use lookup tables
  (see `READONLY_KINDS` pattern in poste-db's ai/actions.lua)
- `gsub` returns 2 values — parenthesize `(s:gsub(...))` when concatenating
- `nvim_buf_set_lines` rejects embedded `\n` — split into lines first
- Headless test runs need isolated `XDG_CACHE_HOME`/`XDG_STATE_HOME`
  (sandbox EPERM); see tests/run.sh

### Testing

- Plenary busted via `./tests/run.sh` (isolated XDG dirs, no sibling rtp —
  this repo has none). Spec per module under `tests/ai/`
- Split pure logic from I/O wiring and test the pure parts exhaustively with
  fixture chunk sequences (sse.lua split-mid-line cases); wiring is tested
  through mock adapters (defer_fn-driven) plus **one real-transport test**
  (`real_stream_spec.lua` spins a local Python SSE server) — mocks cannot
  catch wiring bugs like the chanclose one
- Never assert exact fake-progress details; wait on observable state
  (`vim.wait(…, function() return not stream.is_busy() end)`)
