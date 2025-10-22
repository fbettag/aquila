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
    test "returns chat by default" do
      assert Endpoint.default(model: :"gpt-4o-mini", base_url: "https://api.openai.com/v1") ==
               :chat
    end

    test "returns chat even when url already points to responses" do
      assert Endpoint.default(base_url: "https://proxy.example/v1/responses") == :chat
    end

    test "returns chat for custom host" do
      assert Endpoint.default(base_url: "https://example.com/v1", model: :unknown) == :chat
    end
  end
end
