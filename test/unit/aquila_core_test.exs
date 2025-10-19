defmodule Aquila.CoreTest do
  use ExUnit.Case, async: true

  alias Aquila.Response
  import ExUnit.CaptureLog

  defmodule ResponseTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{}}

    @impl true
    def get(%{url: url}) do
      cond do
        String.contains?(url, "rich") ->
          {:ok,
           %{
             "id" => "resp_rich",
             "output" => [
               %{
                 "type" => "message",
                 "content" => [
                   %{"type" => "output_text", "text" => "Hello"},
                   %{type: "output_text", text: " from Aquila"}
                 ]
               },
               %{"type" => "output_text", "text" => "!"}
             ],
             "usage" => %{"total_tokens" => 3}
           }}

        true ->
          {:ok, "raw-body"}
      end
    end

    @impl true
    def delete(_req), do: {:ok, %{"deleted" => true}}

    @impl true
    def stream(_req, _callback), do: {:ok, make_ref()}
  end

  describe "await_stream/2" do
    test "returns error when no task is registered" do
      assert {:error, :no_stream_task} = Aquila.await_stream(make_ref(), 5)
    end

    test "returns task exit reason" do
      capture_log(fn ->
        ref = make_ref()
        Process.flag(:trap_exit, true)

        task =
          Task.async(fn ->
            Process.sleep(1)
            exit(:stream_failed)
          end)

        try do
          Process.put({:aquila_stream_task, ref}, task)
          assert {:error, {:stream_failed, _}} = Aquila.await_stream(ref, 1000)
        after
          Process.delete({:aquila_stream_task, ref})
          Process.flag(:trap_exit, false)
          flush_exit(task)
        end
      end)
    end
  end

  describe "retrieve_response/2" do
    test "aggregates output text from structured payloads" do
      {:ok, response} =
        Aquila.retrieve_response("resp_rich",
          transport: ResponseTransport,
          base_url: "https://api.test/v1",
          api_key: "key"
        )

      assert %Response{} = response
      assert response.text == "Hello from Aquila!"
      assert response.meta[:response_id] == "resp_rich"
      assert response.meta[:endpoint] == :responses
      assert response.meta[:usage]["total_tokens"] == 3
    end

    test "wraps non-map payloads without raising" do
      {:ok, response} =
        Aquila.retrieve_response("resp_raw",
          transport: ResponseTransport,
          base_url: "https://api.test/v1",
          api_key: "key"
        )

      assert %Response{text: ""} = response
      assert response.meta[:endpoint] == :responses
      assert response.raw == "raw-body"
    end
  end

  describe "transcribe_audio/2" do
    setup do
      path =
        System.tmp_dir!()
        |> Path.join("aquila-audio-" <> Integer.to_string(System.unique_integer([:positive])))

      File.write!(path, "audio")

      on_exit(fn -> File.rm_rf(path) end)

      %{path: path}
    end

    test "raises when form_fields is not a keyword list", %{path: path} do
      assert_raise ArgumentError, ":form_fields must be a keyword list", fn ->
        Aquila.transcribe_audio(path,
          form_fields: [:not, :keyword],
          api_key: "secret",
          http_client: fn _url, _opts -> {:ok, %{status: 200, body: %{}}} end
        )
      end
    end

    test "injects authorization header when missing", %{path: path} do
      parent = self()

      http_client = fn url, opts ->
        send(parent, {:called, url, opts})
        {:ok, %{status: 200, body: %{result: :ok}}}
      end

      assert {:ok, body} =
               Aquila.transcribe_audio(path,
                 api_key: "secret",
                 form_fields: [temperature: 0],
                 headers: [{"x-test", "value"}],
                 http_client: http_client
               )

      assert_receive {:called, url, opts}
      assert String.ends_with?(url, "/audio/transcriptions")

      headers = Keyword.fetch!(opts, :headers)
      assert {"authorization", "Bearer secret"} in headers
      assert {"x-test", "value"} in headers
      assert (is_map(body) and body[:result] == :ok) or body == "%{result: :ok}"
    end
  end

  defp flush_exit(task) do
    receive do
      {:EXIT, ^task, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
