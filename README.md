# poste-ai.nvim

AI assistant for the [Poste](https://github.com/beyondlex/poste.nvim) plugin family — a minimal,
hacker-friendly chat side panel for Neovim.

**Zero dependencies** (besides Neovim ≥ 0.10 and `curl`): no poste.nvim requirement, no Rust binary,
no LLM client library. Streaming goes through `curl -N` + a Lua SSE parser.

Sibling plugins register *contexts* on top of the generic chat UI:

- [poste-db.nvim](https://github.com/beyondlex/poste-db.nvim) — SQL context: `@my-conn/mydb` mentions
  inject schema summaries, AI-written SQL can be executed straight into the dataset view.
- poste-http.nvim — HTTP context (planned).

## Features (V1)

- Chat sidebar (conversation + input buffers), streaming responses with tail-follow and cancel
- Markdown rendering layer (headings, code blocks, lists, quotes) over raw-markdown buffer —
  `R` toggles between rendered and source view, so copying is always exact
- Multiple sessions with persistence (`stdpath("data")/poste-ai/sessions/`)
- `@` mention engine: file references with line ranges (`@src/app.lua(10-20)`) built in;
  contexts add their own (e.g. `@connection/database`)
- Code-block actions on AI replies: execute (via the active context), yank, append to buffer
- OpenAI-compatible providers (OpenAI, DeepSeek, Qwen, Ollama, OpenRouter, vLLM, …)

## Install

With lazy.nvim:

```lua
{
  "beyondlex/poste-ai.nvim",
  opts = {
    providers = {
      openai = {
        base_url = "https://api.openai.com/v1",
        api_key_env = "OPENAI_API_KEY",
        model = "gpt-4o-mini",
      },
    },
  },
}
```

API keys are read from environment variables only (`api_key_env`) — never stored in config files.

## Commands

| Command | Description |
|---|---|
| `:PosteAIChat [context]` | Toggle the chat sidebar (optionally activating a context) |
| `:PosteAIModel` | Pick provider/model at runtime |
| `:PosteAINew` | Start a new session |
| `:PosteAISessions` | Switch between saved sessions |
| `:PosteAICancel` | Cancel the in-flight request |
| `:PosteAIInfo` | Show provider/context/streaming status |
| `:checkhealth poste-ai` | Environment check |

## Context API (for sibling plugins)

```lua
require("poste-ai").register_context("db", {
  system_prompt = function()
    return "You know everything about poste-db.nvim ..."
  end,
  mention = {
    match = function(token) ... end,          -- "@my-conn/mydb" -> ref table or nil
    complete = function(prefix, cb) ... end,  -- candidates for completion popup
    resolve = function(ref, cb) ... end,      -- ref -> markdown context block (async ok)
  },
  codeblock = {
    langs = { "sql" },
    confirm = function(text) return true end, -- return false to abort
    execute = function(text, refs, cb) ... end,
  },
})
```

See `lua/poste-ai/context_api.lua` for the contract and `lua/poste-db/ai/` in poste-db.nvim for a
full implementation.

## License

MIT
