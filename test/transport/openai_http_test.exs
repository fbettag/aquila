defmodule Aquila.OpenAITransportHTTPTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.OpenAI

  setup_all do
    Application.ensure_all_started(:plug_cowboy)
    :ok
  end

  defmodule CapturePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      conn = fetch_query_params(conn)

      case conn.method do
        "GET" ->
          Agent.update(agent, fn _ -> %{method: :get, query: conn.query_params} end)

          body =
            %{
              "query" => conn.query_params
            }
            |> Jason.encode!()

          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, body)

        "DELETE" ->
          {:ok, body, conn} = read_body(conn)
          decoded = if body == "", do: %{}, else: Jason.decode!(body)
          Agent.update(agent, fn _ -> %{method: :delete, body: decoded} end)

          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, ~s({"ok":true}))

        _ ->
          send_resp(conn, 405, "method not allowed")
      end
    end
  end

  defp start_capture_server(opts) do
    ref = unique_ref()
    plug_opts = Keyword.take(opts, [:agent])
    cowboy_opts = [ref: ref, port: Keyword.get(opts, :port, 0)]

    child_spec =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {CapturePlug, plug_opts},
        options: cowboy_opts
      )

    _pid = start_supervised!(child_spec)
    port = :ranch.get_port(ref)
    port
  end

  defp unique_ref do
    ("aquila_http_test_" <> Integer.to_string(System.unique_integer([:positive])))
    |> String.to_atom()
  end

  test "get merges request body map into query params" do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent, :normal) end)

    port = start_capture_server(agent: agent)

    req = %{
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: %{foo: "bar"},
      opts: [],
      endpoint: :responses
    }

    assert {:ok, %{"query" => %{"foo" => "bar"}}} = OpenAI.get(req)
    assert %{method: :get, query: %{"foo" => "bar"}} = Agent.get(agent, & &1)
  end

  test "delete sends JSON body when map provided" do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent, :normal) end)

    port = start_capture_server(agent: agent)

    req = %{
      url: "http://127.0.0.1:#{port}",
      headers: [],
      body: %{foo: "bar"},
      opts: [],
      endpoint: :responses
    }

    assert {:ok, %{"ok" => true}} = OpenAI.delete(req)
    assert %{method: :delete, body: %{"foo" => "bar"}} = Agent.get(agent, & &1)
  end
end
