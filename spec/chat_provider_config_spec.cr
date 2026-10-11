require "spec"
require "json"
require "../src/adamantine/chat_provider_config"

describe Adamantine::Chat::ProviderConfig do
  it "defaults disabled without guessing a model and round-trips through JSON" do
    config = Adamantine::Chat::ProviderConfig.new

    config.enabled.should be_false
    config.model.should eq("")
    config.validation_error.should be_nil

    decoded = Adamantine::Chat::ProviderConfig.from_json(JSON.parse(config.to_json))
    decoded.enabled.should be_false
    decoded.model.should eq("")
    decoded.endpoint.should eq("https://api.openai.com/v1/chat/completions")
    decoded.key_env.should eq("OPENAI_API_KEY")
    decoded.max_completion_tokens.should eq(4096)

    JSON.parse(config.to_json)["enabled"].as_bool.should be_false
    decoded.validation_error.should be_nil
  end

  it "requires an explicit model only when enabled" do
    disabled = Adamantine::Chat::ProviderConfig.new(enabled: false, model: "")
    enabled = Adamantine::Chat::ProviderConfig.new(enabled: true, model: "")

    disabled.validation_error.should be_nil
    enabled.validation_error.should_not be_nil
  end

  it "accepts HTTPS remote endpoints and literal loopback HTTP only" do
    https = Adamantine::Chat::ProviderConfig.new(enabled: true, model: "user/model")
    local_v4 = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: "http://127.0.0.1:8844/v1/chat/completions",
      model: "local-model",
      key_env: ""
    )
    local_v6 = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: "http://[::1]:8844/v1/chat/completions",
      model: "local-model",
      key_env: ""
    )
    cleartext_remote = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: "http://localhost:8844/v1/chat/completions",
      model: "local-model",
      key_env: ""
    )

    https.validation_error.should be_nil
    local_v4.validation_error.should be_nil
    local_v6.validation_error.should be_nil
    cleartext_remote.validation_error.should_not be_nil
  end

  it "rejects endpoint userinfo, query, fragment, controls, ambiguous authorities, and traversal" do
    [
      "https://user:password@example.test/v1/chat/completions",
      "https://example.test/v1/chat/completions?api_key=secret",
      "https://example.test/v1/chat/completions#section",
      "https://example.test/v1/chat/completions\nX-Evil: yes",
      "https://example.test/v1/chat/completions/../responses",
      "https://example.test:bad/v1/chat/completions",
      "https://example.test:/v1/chat/completions",
      "https://exa%mple.test/v1/chat/completions",
      "https://host%0d.evil/v1/chat/completions",
      "https://example.test\\evil/v1/chat/completions",
      "https:///v1/chat/completions",
      "https://[not-ipv6]/v1/chat/completions",
      "https://example.test:0/v1/chat/completions",
      "https://example.test:65536/v1/chat/completions",
      "http://%31%32%37.0.0.1/v1/chat/completions",
    ].each do |endpoint|
      config = Adamantine::Chat::ProviderConfig.new(
        enabled: true,
        endpoint: endpoint,
        model: "explicit-model"
      )
      config.validation_error.should_not be_nil
    end
  end

  it "requires a named credential reference except for literal loopback" do
    missing_remote_key = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      model: "explicit-model",
      key_env: ""
    )
    unsafe_key_name = Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      model: "explicit-model",
      key_env: "OPENAI_API_KEY\r\nX-Leak: yes"
    )

    missing_remote_key.validation_error.should_not be_nil
    unsafe_key_name.validation_error.should_not be_nil
  end

  it "rejects invalid token budgets and malformed persisted data without raising" do
    [0, -1, 32769].each do |limit|
      config = Adamantine::Chat::ProviderConfig.new(
        enabled: true,
        model: "explicit-model",
        max_completion_tokens: limit
      )
      config.validation_error.should_not be_nil
    end

    bad = Adamantine::Chat::ProviderConfig.from_json(JSON.parse(%({"enabled":"yes"})))
    bad.validation_error.should_not be_nil
  end
end
