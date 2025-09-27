defmodule Aquila.EndpointTest do
  use ExUnit.Case, async: true

  alias Aquila.Endpoint

  test "choose respects explicit endpoint" do
    assert Endpoint.choose(endpoint: :chat) == :chat
  end

  test "choose uses selector" do
    assert Endpoint.choose(endpoint_selector: fn _ -> :responses end) == :responses
  end

  describe "default/1" do
    test "returns responses for known model on openai host" do
      assert Endpoint.default(model: :"gpt-4o-mini", base_url: "https://api.openai.com/v1") ==
               :responses
    end

    test "returns responses when url already points to responses" do
      assert Endpoint.default(base_url: "https://proxy.example/v1/responses") == :responses
    end

    test "falls back to chat for custom host" do
      assert Endpoint.default(base_url: "https://example.com/v1", model: :unknown) == :chat
    end
  end

  test "responses_model?/1 strips -latest" do
    assert Endpoint.responses_model?("gpt-4o-latest")
    refute Endpoint.responses_model?("gpt-3.5-turbo")
  end
end
