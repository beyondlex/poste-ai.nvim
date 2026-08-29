describe("poste-ai.config", function()
  local config = require("poste-ai.config")

  after_each(function()
    -- restore defaults for later specs
    config.config = vim.deepcopy(config.defaults)
  end)

  describe("merge", function()
    it("deep-merges nested tables", function()
      config.merge({ chat = { split_width = 80 } })
      assert.are.equal(80, config.config.chat.split_width)
      assert.are.equal("right", config.config.chat.split_position)
    end)

    it("replaces scalars", function()
      config.merge({ provider = "custom" })
      assert.are.equal("custom", config.config.provider)
    end)
  end)

  describe("get_keymap", function()
    it("returns defaults", function()
      assert.are.equal("q", config.get_keymap("chat_window", "close"))
      assert.are.equal("fallback", config.get_keymap("missing_section", "x", "fallback"))
    end)

    it("supports overrides", function()
      config.merge({ keymaps = { chat_window = { close = "Q" } } })
      assert.are.equal("Q", config.get_keymap("chat_window", "close"))
    end)

    it("supports disabling with false", function()
      config.merge({ keymaps = { chat_window = { close = false } } })
      -- false disables the keymap entirely, even against a fallback default
      assert.is_nil(config.get_keymap("chat_window", "close"))
      assert.is_nil(config.get_keymap("chat_window", "close", "dflt"))
    end)
  end)

  describe("format_key_string", function()
    it("shows <leader> with the actual leader", function()
      vim.g.mapleader = ","
      assert.are.equal(",aa", config.format_key_string("<leader>aa"))
      vim.g.mapleader = " "
      assert.are.equal("<Space>aa", config.format_key_string("<leader>aa"))
    end)

    it("maps named keys", function()
      assert.are.equal("Enter", config.format_key_string("<CR>"))
    end)
  end)

  describe("resolve_provider", function()
    it("errors when the model is unset", function()
      local _, err = config.resolve_provider()
      assert.truthy(err:find("model"))
    end)

    it("resolves a fully configured provider", function()
      config.merge({ providers = { openai = { model = "gpt-test" } } })
      local cfg = config.resolve_provider()
      assert.are.equal("gpt-test", cfg.model)
    end)
  end)

  it("reads the api key from the environment", function()
    vim.env.POSTE_AI_TEST_KEY = "abc123"
    assert.are.equal("abc123", config.api_key({ api_key_env = "POSTE_AI_TEST_KEY" }))
    assert.is_nil(config.api_key({ api_key_env = "POSTE_AI_DEFINITELY_NOT_SET" }))
    vim.env.POSTE_AI_TEST_KEY = nil
  end)

  it("defaults the sessions dir", function()
    config.merge({ sessions_dir = "/tmp/custom-sessions" })
    assert.are.equal("/tmp/custom-sessions", config.sessions_dir())
    config.config = vim.deepcopy(config.defaults)
    assert.truthy(config.sessions_dir():find("poste%-ai"))
  end)
end)
