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
end
