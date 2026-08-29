-- Real-transport integration test: spawns a local Python SSE server and runs
-- the full curl → jobstart → SSE → conversation pipeline. Skipped when
-- python3 is unavailable. This is the test that catches wiring bugs
-- (e.g. chanclose killing stdout) that pure-function mocks cannot.

local config = require("poste-ai.config")
local stream = require("poste-ai.chat.stream")
local window = require("poste-ai.chat.window")
local session = require("poste-ai.chat.session")

local PORT = 18652 + math.random(0, 200)
local SERVER = [[
import http.server, json, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for c in ["Hello", " from", " real SSE!"]:
            ev = json.dumps({"choices": [{"delta": {"content": c}}]})
            self.wfile.write(("data: %s\n\n" % ev).encode()); self.wfile.flush()
        # regression: one event split mid-JSON across two writes, with a
        # pause so curl reads them as separate stdout chunks — the transport
        # chunk boundary lands inside an SSE line
        self.wfile.write(b'data: {"choices": [{"delta": {"content": " spl'); self.wfile.flush()
        time.sleep(0.1)
        self.wfile.write(b'it!"}}]}\n\n'); self.wfile.flush()
        fin = json.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(("data: %s\n\n" % fin).encode()); self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", __PORT__), H)
open(__READY__, "w").write("ok")
srv.serve_forever()
]]

describe("poste-ai real streaming transport", function()
  local tmp_dir
  local server_pid
  local saved_no_proxy

  local function spawn_server()
    local script = vim.fn.tempname() .. ".py"
    local ready_file = vim.fn.tempname() .. ".ready"
    vim.fn.writefile(
      vim.split(SERVER:gsub("__PORT__", tostring(PORT)):gsub("__READY__", '"' .. ready_file .. '"'),
        "\n", { plain = true }),
      script)
    local ok, handle = pcall(vim.system, { "python3", script }, { detach = true })
    if not ok then return nil end
    server_pid = handle
    -- the server writes the ready file only after the socket is bound
    vim.wait(3000, function() return vim.fn.filereadable(ready_file) == 1 end, 50)
    return handle
  end

  before_each(function()
    if vim.fn.executable("python3") == 0 then pending("python3 not available") return end
    -- bypass any ambient HTTP proxy for the localhost server (curl honors these)
    saved_no_proxy = { vim.env.no_proxy, vim.env.NO_PROXY }
    vim.env.no_proxy = "127.0.0.1"
    vim.env.NO_PROXY = "127.0.0.1"
    tmp_dir = vim.fn.tempname() .. "-real-stream"
    config.merge({ sessions_dir = tmp_dir })
    config.config.provider = "openai"
    config.config.providers.openai = {
      base_url = "http://127.0.0.1:" .. PORT .. "/v1",
      model = "mock-1",
      api_key_env = "",
    }
    session.set_current(nil)
    window.open()
    require("poste-ai.chat.conversation").set_messages({})
    spawn_server()
  end)

  after_each(function()
    stream.force_reset()
    window.close()
    if server_pid then pcall(function() server_pid:kill() end) end
    vim.fn.delete(tmp_dir, "rf")
    config.config = vim.deepcopy(config.defaults)
    session.set_current(nil)
    vim.env.no_proxy, vim.env.NO_PROXY = saved_no_proxy[1], saved_no_proxy[2]
  end)

  it("streams a real curl SSE response end-to-end", function()
    if not server_pid then pending("server did not start") return end
    assert.is_true(stream.send("hello server"))
    local finished = vim.wait(10000, function() return not stream.is_busy() end)
    assert.is_true(finished)

    local lines = table.concat(
      vim.api.nvim_buf_get_lines(window.conversation_buf(), 0, -1, false), "\n")
    -- " split!" arrives in an SSE line split across two stdout chunks; a
    -- wiring bug that injects a newline at the chunk boundary drops it
    assert.truthy(lines:find("Hello from real SSE! split!"))

    local msgs = session.current().messages
    assert.are.equal("Hello from real SSE! split!", msgs[#msgs].text)
  end)
end)
