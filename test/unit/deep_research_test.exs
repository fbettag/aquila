defmodule Aquila.DeepResearchTest do
  use ExUnit.Case

  alias Aquila.DeepResearch

  defmodule TransportStub do
    @behaviour Aquila.Transport

    def configure(opts) do
      :persistent_term.put({__MODULE__, :receiver}, Keyword.get(opts, :receiver))
    end

    def reset do
      :persistent_term.erase({__MODULE__, :receiver})
    end

    @impl true
    def post(req) do
      notify({:post, req})
      {:ok, %{"id" => "resp_test", "status" => "in_progress"}}
    end

    @impl true
    def get(req) do
      notify({:get, req})
      {:ok, %{"id" => "resp_test"}}
    end

    @impl true
    def delete(req) do
      notify({:delete, req})
      {:ok, %{"id" => "resp_test"}}
    end

    @impl true
    def stream(_req, _callback) do
      {:ok, make_ref()}
    end

    defp notify(event) do
      if receiver = :persistent_term.get({__MODULE__, :receiver}, nil) do
        send(receiver, event)
      end
    end
  end

  setup do
    original_transport = Application.get_env(:aquila, :transport)
    original_config = Application.get_env(:aquila, :openai, [])

    TransportStub.configure(receiver: self())

    Application.put_env(:aquila, :transport, TransportStub)
    Application.put_env(:aquila, :openai, Keyword.put(original_config, :api_key, "test-key"))

    on_exit(fn ->
      Application.put_env(:aquila, :transport, original_transport)
      Application.put_env(:aquila, :openai, original_config)
      TransportStub.reset()
      flush_messages()
    end)

    :ok
  end

  test "create issues background Deep Research request" do
    assert {:ok, %{"status" => "in_progress"}} =
             DeepResearch.create("Investigate Mars missions",
               base_url: "https://example.com/v1",
               api_key: "direct-key"
             )

    assert_receive {:post,
                    %{endpoint: :responses, url: "https://example.com/v1/responses", body: body}}

    assert body.background == true
    assert body.stream == false
    assert Enum.any?(body.tools, &(tool_type(&1) == "web_search_preview"))
  end

  test "respects existing web_search_preview tool configuration" do
    assert {:ok, %{"status" => "in_progress"}} =
             DeepResearch.create("Investigate",
               base_url: "https://example.com/v1",
               api_key: "direct-key",
               tools: [%{type: "web_search_preview", search_context_size: "large"}]
             )

    assert_receive {:post, %{body: body}}

    web_search_tools = Enum.filter(body.tools, &(tool_type(&1) == "web_search_preview"))

    assert length(web_search_tools) == 1
    tool = hd(web_search_tools)

    assert Map.get(tool, :search_context_size) == "large" or
             Map.get(tool, "search_context_size") == "large"
  end

  test "cancel posts to cancel endpoint" do
    assert {:ok, %{"id" => "resp_test"}} =
             DeepResearch.cancel("resp_123",
               base_url: "https://example.com/v1",
               api_key: "direct-key"
             )

    assert_receive {:post, %{url: "https://example.com/v1/responses/resp_123/cancel"}}
  end

  defp tool_type(tool), do: Map.get(tool, :type) || Map.get(tool, "type")

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
