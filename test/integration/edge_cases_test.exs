defmodule Aquila.EdgeCasesTest do
  use ExUnit.Case, async: true

  defmodule SimpleTransport do
    @behaviour Aquila.Transport

    def post(_req), do: {:ok, %{}}
    def get(_req), do: {:ok, %{}}

    def delete(req) do
      send(self(), {:delete_called, req})
      {:ok, %{"deleted" => true}}
    end

    def stream(_req, callback) do
      callback.(%{type: :delta, content: "ok"})
      callback.(%{type: :done, status: :completed, meta: %{}})
      {:ok, make_ref()}
    end
  end

  test "delete_response calls transport delete" do
    {:ok, result} =
      Aquila.delete_response("resp_123", transport: SimpleTransport, api_key: "test")

    assert result["deleted"] == true
    assert_received {:delete_called, _req}
  end

  test "retrieve_response calls transport get" do
    defmodule GetTransport do
      @behaviour Aquila.Transport
      def post(_req), do: {:ok, %{}}
      def delete(_req), do: {:ok, %{}}
      def stream(_req, _callback), do: {:ok, make_ref()}

      def get(req) do
        send(self(), {:get_called, req})

        {:ok,
         %{
           "id" => "resp_test",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "response"}]
             }
           ]
         }}
      end
    end

    {:ok, response} =
      Aquila.retrieve_response("resp_test", transport: GetTransport, api_key: "test")

    assert response.text == "response"
    assert_received {:get_called, _req}
  end
end
