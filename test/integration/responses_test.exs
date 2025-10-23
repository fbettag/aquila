defmodule Aquila.ResponsesHelperTest do
  use ExUnit.Case, async: true

  defmodule StubTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req) do
      {:error, :not_used}
    end

    @impl true
    def get(req) do
      notify(:get, req)

      case Process.get(:stub_transport_get, :ok) do
        :ok ->
          {:ok,
           %{
             "id" => "resp_stub",
             "status" => "completed",
             "model" => "gpt-4o-mini",
             "metadata" => %{"tag" => "demo"},
             "usage" => %{"total_tokens" => 12},
             "output" => [
               %{
                 "type" => "message",
                 "content" => [
                   %{"type" => "output_text", "text" => "Hello"},
                   %{"type" => "output_text", "text" => " world"}
                 ]
               }
             ]
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def delete(req) do
      notify(:delete, req)

      case Process.get(:stub_transport_delete, :ok) do
        :ok -> {:ok, %{"deleted" => true, "id" => "resp_stub"}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def stream(_req, _callback) do
      {:ok, make_ref()}
    end

    defp notify(kind, req) do
      if pid = Process.get(:transport_test_pid) do
        send(pid, {:transport_call, kind, req})
      end
    end
  end

  setup do
    Process.put(:transport_test_pid, self())

    on_exit(fn ->
      Process.delete(:transport_test_pid)
      Process.delete(:stub_transport_get)
      Process.delete(:stub_transport_delete)
    end)

    :ok
  end

  test "retrieve_response/2 builds response struct" do
    {:ok, response} =
      Aquila.retrieve_response("resp_stub",
        transport: StubTransport,
        api_key: "abc",
        base_url: "https://example.com/api"
      )

    assert response.text == "Hello world"
    assert response.meta[:response_id] == "resp_stub"
    assert response.meta[:metadata] == %{"tag" => "demo"}

    assert_receive {:transport_call, :get,
                    %{url: "https://example.com/api/responses/resp_stub", headers: headers}}

    assert {"authorization", "Bearer abc"} in headers
  end

  test "retrieve_response/2 bubbles transport errors" do
    Process.put(:stub_transport_get, {:error, :timeout})

    assert {:error, :timeout} =
             Aquila.retrieve_response("resp_stub",
               transport: StubTransport,
               api_key: "abc"
             )
  end

  test "delete_response/2 returns transport body" do
    assert {:ok, %{"deleted" => true, "id" => "resp_stub"}} =
             Aquila.delete_response("resp_stub",
               transport: StubTransport,
               api_key: "abc",
               base_url: "https://api.openai.com/v1"
             )

    assert_receive {:transport_call, :delete,
                    %{url: "https://api.openai.com/v1/responses/resp_stub"}}
  end

  test "delete_response/2 bubbles errors" do
    Process.put(:stub_transport_delete, {:error, :forbidden})

    assert {:error, :forbidden} =
             Aquila.delete_response("resp_stub",
               transport: StubTransport,
               api_key: "abc"
             )
  end

  test "retrieve_response/2 accepts api_key as {:system, var}" do
    # Set an environment variable for testing
    System.put_env("TEST_API_KEY", "test_key_value")

    on_exit(fn -> System.delete_env("TEST_API_KEY") end)

    {:ok, _response} =
      Aquila.retrieve_response("resp_stub",
        transport: StubTransport,
        api_key: {:system, "TEST_API_KEY"},
        base_url: "https://example.com/api"
      )

    assert_receive {:transport_call, :get, %{headers: headers}}

    assert {"authorization", "Bearer test_key_value"} in headers
  end

  test "Aquila.ask with responses endpoint does not set store by default" do
    response =
      Aquila.ask("ping",
        model: "openai/gpt-4o",
        endpoint: :responses,
        transport: Aquila.CaptureTransport
      )

    assert response.text == ""

    assert_receive {:stream_request, req}

    body = Map.get(req, :body) || Map.get(req, "body")

    refute Map.has_key?(body, :store)
    refute Map.has_key?(body, "store")
    assert Map.get(body, :store) == nil
    assert Map.get(body, "store") == nil
  end

  test "Aquila.ask with responses endpoint handles multipart content (content parts)" do
    alias Aquila.Message

    # Create a message with multiple content parts, similar to file upload scenario
    messages = [
      Message.new(:user, [
        %{type: "text", text: "What text is in the file I just uploaded?"},
        %{type: "text", text: "PDF content from test_file.pdf:\n\nCassian Andor\n\f"}
      ])
    ]

    response =
      Aquila.ask(messages,
        model: "openai/gpt-4o",
        endpoint: :responses,
        transport: Aquila.CaptureTransport
      )

    assert response.text == ""

    assert_receive {:stream_request, req}

    body = Map.get(req, :body) || Map.get(req, "body")
    input = Map.get(body, :input) || Map.get(body, "input")

    # Verify the input contains our message with content parts
    assert is_list(input)
    assert length(input) == 1

    [message] = input
    content = Map.get(message, :content) || Map.get(message, "content")

    # Content should be a list of content parts, NOT wrapped in another list
    assert is_list(content)
    assert length(content) == 2

    # Verify both content parts are present
    [part1, part2] = content
    assert is_map(part1)
    assert is_map(part2)

    # Content parts should be passed through as-is
    text1 = Map.get(part1, :text) || Map.get(part1, "text")
    text2 = Map.get(part2, :text) || Map.get(part2, "text")

    assert text1 == "What text is in the file I just uploaded?"
    assert text2 == "PDF content from test_file.pdf:\n\nCassian Andor\n\f"
  end
end
