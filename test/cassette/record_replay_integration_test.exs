defmodule Aquila.TransportRecordReplayTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.{Record, Replay, Cassette}

  defmodule StubTransport do
    @behaviour Aquila.Transport

    def post(_req) do
      fetch(:post) || {:ok, %{"status" => "ok"}}
    end

    def get(_req) do
      fetch(:get) || {:ok, %{"status" => "ok"}}
    end

    def delete(_req) do
      fetch(:delete) || {:ok, %{"status" => "ok"}}
    end

    def stream(_req, callback) do
      fetch(:stream, [])
      |> Enum.each(callback)

      {:ok, make_ref()}
    end

    def set_post(response), do: Process.put({__MODULE__, :post}, response)
    def set_stream(events), do: Process.put({__MODULE__, :stream}, events)
    def set_get(response), do: Process.put({__MODULE__, :get}, response)
    def set_delete(response), do: Process.put({__MODULE__, :delete}, response)

    defp fetch(key, default \\ nil) do
      case Process.get({__MODULE__, key}, default) do
        {:raise, message} -> raise message
        other -> other
      end
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "aquila_record_test_#{System.unique_integer([:positive])}")

    Application.put_env(:aquila, :recorder, path: tmp, transport: StubTransport)

    on_exit(fn ->
      Application.delete_env(:aquila, :recorder)
      File.rm_rf(tmp)
      Process.delete({StubTransport, :post})
      Process.delete({StubTransport, :get})
      Process.delete({StubTransport, :delete})
      Process.delete({StubTransport, :stream})
    end)

    {:ok, tmp_dir: tmp}
  end

  defp base_req(opts \\ []) do
    %{
      endpoint: :responses,
      url: "https://example.com/v1/responses",
      headers: [],
      body: %{prompt: "hello"},
      opts: opts
    }
  end

  test "record post writes cassette and replays", %{tmp_dir: _tmp} do
    cassette = "record/post"
    req = base_req(cassette: cassette, cassette_index: 1)

    StubTransport.set_post({:ok, %{"result" => "fresh"}})
    assert {:ok, %{"result" => "fresh"}} = Record.post(req)

    meta_path = Cassette.meta_path(cassette)
    json_path = Cassette.post_path(cassette, 1)
    assert File.exists?(meta_path)
    assert File.exists?(json_path)

    StubTransport.set_post({:raise, "should not call transport on replay"})
    assert {:ok, %{"result" => "fresh"}} = Record.post(req)
  end

  test "record stream persists events and replays" do
    cassette = "record/stream"
    req = base_req(cassette: cassette, cassette_index: 1)

    events = [
      %{type: :response_ref, id: "resp_1"},
      %{type: :delta, content: "Hi"},
      %{type: :usage, usage: %{"tokens" => 3}},
      %{type: :error, error: %{reason: "boom"}},
      %{type: :event, payload: %{foo: "bar"}},
      %{type: :done, status: :completed, meta: %{}}
    ]

    StubTransport.set_stream(events)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    callback = fn event -> Agent.update(agent, &[event | &1]) end

    assert {:ok, _} = Record.stream(req, callback)

    recorded = Agent.get(agent, &Enum.reverse/1)
    assert Enum.map(recorded, & &1.type) == Enum.map(events, & &1.type)
    assert %{type: :error, error: %{reason: "boom"}} = Enum.at(recorded, 3)
    assert %{type: :event, payload: %{foo: "bar"}} = Enum.at(recorded, 4)

    # Replay should not hit the transport again
    StubTransport.set_stream([])
    Agent.update(agent, fn _ -> [] end)

    assert {:ok, _} = Record.stream(req, callback)
    replayed = Agent.get(agent, &Enum.reverse/1)
    assert Enum.map(replayed, & &1.type) == Enum.map(events, & &1.type)
  end

  test "replay post returns error when cassette missing" do
    req = base_req()
    assert {:error, :missing_cassette} = Replay.post(req)
  end

  test "replay raises when http method differs" do
    cassette = "replay/method"
    index = 1
    body = %{prompt: "method"}
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, body)

    Cassette.write_meta(cassette, index, %{
      "body_hash" => Cassette.canonical_hash(body),
      "method" => "post"
    })

    Cassette.ensure_dir(Cassette.post_path(cassette, index))
    File.write!(Cassette.post_path(cassette, index), Jason.encode!(%{"ok" => true}))

    assert {:ok, %{"ok" => true}} = Replay.post(req)

    get_req = Map.put(req, :body, nil)
    assert_raise RuntimeError, ~r/Cassette method mismatch/, fn -> Replay.get(get_req) end
  end

  test "replay stream rejects prompt mismatches", %{tmp_dir: _tmp} do
    cassette = "replay/mismatch"
    index = 1
    req = base_req(cassette: cassette, cassette_index: index)

    meta = %{"body_hash" => Cassette.canonical_hash(%{prompt: "different"})}
    Cassette.write_meta(cassette, index, meta)
    Cassette.ensure_dir(Cassette.sse_path(cassette))
    File.write!(Cassette.sse_path(cassette), "")

    assert_raise RuntimeError, fn -> Replay.stream(req, fn _ -> :ok end) end
  end

  test "replay stream decodes events", %{tmp_dir: _tmp} do
    cassette = "replay/events"
    index = 1
    body = %{prompt: "decode"}
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, body)

    meta = %{"body_hash" => Cassette.canonical_hash(body)}
    Cassette.write_meta(cassette, index, meta)

    events = [
      %{"type" => "delta", "content" => "Hello", "request_id" => index},
      %{"type" => "tool_call", "id" => "call", "name" => "fn", "request_id" => index},
      %{
        "type" => "tool_call_end",
        "id" => "call",
        "name" => "fn",
        "args" => %{"ok" => true},
        "request_id" => index
      },
      %{"type" => "usage", "usage" => %{"prompt_tokens" => 1}, "request_id" => index},
      %{
        "type" => "done",
        "status" => "succeeded",
        "meta" => %{"id" => "resp"},
        "request_id" => index
      }
    ]

    contents = Enum.map(events, &Jason.encode!/1) |> Enum.join("\n")
    File.write!(Cassette.sse_path(cassette), contents)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    callback = fn event -> Agent.update(agent, &[event | &1]) end

    assert {:ok, _} = Replay.stream(req, callback)

    decoded = Agent.get(agent, &Enum.reverse/1)

    assert [
             %{type: :delta, content: "Hello"},
             %{type: :tool_call, id: "call", name: "fn"},
             %{type: :tool_call_end, id: "call", name: "fn", args: %{"ok" => true}},
             %{type: :usage, usage: %{"prompt_tokens" => 1}},
             %{type: :done, status: :succeeded, meta: %{"id" => "resp"}}
           ] = decoded
  end

  test "record post without cassette proxies transport" do
    StubTransport.set_post({:ok, %{"proxied" => true}})
    assert {:ok, %{"proxied" => true}} = Record.post(base_req())
  end

  test "record stream without cassette proxies transport" do
    events = [%{type: :delta, content: "free"}, %{type: :done, status: :completed}]
    StubTransport.set_stream(events)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    callback = fn event -> Agent.update(agent, &[event | &1]) end

    assert {:ok, _} = Record.stream(base_req(), callback)
    assert Agent.get(agent, &Enum.reverse/1) == events
  end

  test "record post propagates errors" do
    StubTransport.set_post({:error, :timeout})
    req = base_req(cassette: "errors/post", cassette_index: 1)

    assert {:error, :timeout} = Record.post(req)
  end

  test "replay post loads recorded body" do
    cassette = "replay/post"
    index = 1
    body = %{prompt: "load"}
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, body)

    Cassette.write_meta(cassette, index, %{"body_hash" => Cassette.canonical_hash(body)})
    Cassette.ensure_dir(Cassette.post_path(cassette, index))
    File.write!(Cassette.post_path(cassette, index), Jason.encode!(%{"ok" => true}))

    assert {:ok, %{"ok" => true}} = Replay.post(req)
  end

  test "replay stream handles metadata errors" do
    cassette = "replay/meta_missing"
    index = 1
    req = base_req(cassette: cassette, cassette_index: index)

    Cassette.ensure_dir(Cassette.sse_path(cassette))
    File.write!(Cassette.sse_path(cassette), "")

    assert_raise RuntimeError, fn -> Replay.stream(req, fn _ -> :ok end) end
  end

  test "record stream fails when cassette meta missing" do
    cassette = "record/meta_missing"
    req = base_req(cassette: cassette, cassette_index: 1)

    StubTransport.set_stream([
      %{type: :done, status: :completed, meta: %{}}
    ])

    assert {:ok, _} = Record.stream(req, fn _ -> :ok end)

    meta_path = Cassette.meta_path(cassette)
    File.rm!(meta_path)
    File.mkdir_p!(meta_path)

    assert_raise File.Error, fn ->
      Record.stream(req, fn _ -> :ok end)
    end
  end

  test "record stream overwrites corrupted meta" do
    cassette = "record/meta_invalid"
    req = base_req(cassette: cassette, cassette_index: 1)

    StubTransport.set_stream([
      %{type: :done, status: :completed, meta: %{}}
    ])

    assert {:ok, _} = Record.stream(req, fn _ -> :ok end)

    meta_path = Cassette.meta_path(cassette)
    File.write!(meta_path, "{invalid}")

    # Record overwrites the corrupted meta and succeeds
    assert {:ok, _} = Record.stream(req, fn _ -> :ok end)
  end

  test "record post hashes nil body" do
    cassette = "record/nil_body"

    req =
      base_req(cassette: cassette, cassette_index: 1)
      |> Map.put(:body, nil)

    StubTransport.set_post({:ok, %{"ok" => true}})
    assert {:ok, %{"ok" => true}} = Record.post(req)

    {:ok, meta} = Cassette.read_meta(cassette, 1)
    assert meta["body"] == nil
  end

  test "replay post handles nil body hash" do
    cassette = "replay/nil_body"
    index = 1
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, nil)

    Cassette.write_meta(cassette, index, %{"body_hash" => Cassette.canonical_hash(:no_body)})
    Cassette.ensure_dir(Cassette.post_path(cassette, index))
    File.write!(Cassette.post_path(cassette, index), Jason.encode!(%{"ok" => true}))

    assert {:ok, %{"ok" => true}} = Replay.post(req)
  end

  test "replay stream returns missing cassette error" do
    assert {:error, :missing_cassette} = Replay.stream(base_req(), fn _ -> :ok end)
  end

  test "replay stream decodes nil status" do
    cassette = "replay/nil_status"
    index = 1
    body = %{prompt: "nil"}
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, body)

    Cassette.write_meta(cassette, index, %{"body_hash" => Cassette.canonical_hash(body)})

    events = [
      %{"type" => "done", "request_id" => index}
    ]

    File.write!(
      Cassette.sse_path(cassette),
      Enum.map(events, &Jason.encode!/1) |> Enum.join("\n")
    )

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert {:ok, _} = Replay.stream(req, fn event -> Agent.update(agent, &[event | &1]) end)

    assert [%{type: :done, status: :completed}] = Agent.get(agent, &Enum.reverse/1)
  end

  test "replay stream decodes extended events" do
    cassette = "replay/extended"
    index = 1
    body = %{prompt: "extended"}
    req = base_req(cassette: cassette, cassette_index: index) |> Map.put(:body, body)

    Cassette.write_meta(cassette, index, %{"body_hash" => Cassette.canonical_hash(body)})

    events = [
      %{"type" => "message", "content" => "msg", "request_id" => index},
      %{"type" => "response_ref", "id" => "resp", "request_id" => index},
      %{"type" => "event", "foo" => "bar", "request_id" => index},
      %{"type" => "error", "error" => %{"message" => "boom"}, "request_id" => index},
      %{"type" => "meta", "request_id" => index},
      %{"unexpected" => "value", "request_id" => index},
      %{"type" => "done", "status" => "requires_action", "request_id" => index},
      %{"type" => "done", "status" => "queued", "request_id" => index}
    ]

    contents = Enum.map(events, &Jason.encode!/1) |> Enum.join("\n")
    contents = contents <> "\n"
    File.write!(Cassette.sse_path(cassette), contents)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert {:ok, _} = Replay.stream(req, fn event -> Agent.update(agent, &[event | &1]) end)

    decoded = Agent.get(agent, &Enum.reverse/1)

    assert [
             %{type: :message, content: "msg"},
             %{type: :response_ref, id: "resp"},
             %{type: :event, payload: %{"foo" => "bar", "request_id" => 1}},
             %{type: :error, error: %{"message" => "boom"}},
             %{type: :event, payload: %{"unexpected" => "value", "request_id" => 1}},
             %{type: :done, status: :requires_action, meta: %{}}
           ] = decoded
  end
end
