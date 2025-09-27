defmodule Aquila.TransportRecordTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.{Record, Cassette}

  defmodule FakeTransport do
    @behaviour Aquila.Transport

    def post(_req) do
      increment(:post)
      {:ok, %{"ok" => true}}
    end

    def get(_req) do
      increment(:get)
      {:ok, %{"ok" => true}}
    end

    def delete(_req) do
      increment(:delete)
      {:ok, %{"ok" => true}}
    end

    def stream(_req, callback) do
      increment(:stream)
      callback.(%{type: :delta, content: "chunk"})
      callback.(%{type: :done, status: :completed, meta: %{}})
      {:ok, make_ref()}
    end

    defp increment(key) do
      counter = Process.get({__MODULE__, key}, 0)
      Process.put({__MODULE__, key}, counter + 1)
    end

    def calls(key), do: Process.get({__MODULE__, key}, 0)
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "aquila-record-test-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    original = Application.get_env(:aquila, :recorder, [])

    Application.put_env(:aquila, :recorder,
      path: tmp,
      transport: FakeTransport
    )

    Process.put({FakeTransport, :post}, 0)
    Process.put({FakeTransport, :get}, 0)
    Process.put({FakeTransport, :delete}, 0)
    Process.put({FakeTransport, :stream}, 0)

    on_exit(fn ->
      Application.put_env(:aquila, :recorder, original)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  test "records and replays post requests" do
    req = base_req(%{body: %{foo: "bar"}})

    assert {:ok, %{"ok" => true}} = Record.post(req)
    assert FakeTransport.calls(:post) == 1

    assert Cassette.exists?("record-demo", 1, :post)

    assert {:ok, %{"ok" => true}} = Record.post(req)
    assert FakeTransport.calls(:post) == 1
  end

  test "redacts authorization headers in meta" do
    cassette = "record-auth"

    req =
      base_req(%{
        headers: [{"authorization", "Bearer secret"}, {"x-custom", "value"}],
        opts: [cassette: cassette, cassette_index: 1]
      })

    assert {:ok, %{"ok" => true}} = Record.post(req)

    meta =
      cassette
      |> Cassette.meta_path()
      |> File.read!()
      |> Jason.decode!()

    assert [
             ["authorization", "[redacted]"],
             ["x-custom", "value"]
           ] == meta["headers"]
  end

  test "records and replays get requests" do
    req = base_req(%{body: nil, opts: [cassette: "record-demo-get", cassette_index: 1]})

    assert {:ok, %{"ok" => true}} = Record.get(req)
    assert FakeTransport.calls(:get) == 1

    assert Cassette.exists?("record-demo-get", 1, :post)

    assert {:ok, %{"ok" => true}} = Record.get(req)
    assert FakeTransport.calls(:get) == 1
  end

  test "records and replays delete requests" do
    req = base_req(%{body: nil, opts: [cassette: "record-demo-delete", cassette_index: 1]})

    assert {:ok, %{"ok" => true}} = Record.delete(req)
    assert FakeTransport.calls(:delete) == 1

    assert {:ok, %{"ok" => true}} = Record.delete(req)
    assert FakeTransport.calls(:delete) == 1
  end

  test "raises when http method changes for existing cassette" do
    cassette = "record-method"
    post_req = base_req(%{opts: [cassette: cassette, cassette_index: 1]})
    assert {:ok, %{"ok" => true}} = Record.post(post_req)

    get_req = base_req(%{body: nil, opts: [cassette: cassette, cassette_index: 1]})

    assert_raise RuntimeError, ~r/Cassette method mismatch/, fn ->
      Record.get(get_req)
    end
  end

  test "records and replays stream requests" do
    req = base_req(%{body: %{foo: "bar"}})
    parent = self()

    callback = fn event -> send(parent, {:event, event}) end

    assert {:ok, ref} = Record.stream(req, callback)
    assert is_reference(ref)
    assert FakeTransport.calls(:stream) == 1

    assert_receive {:event, %{type: :delta, content: "chunk"}}
    assert_receive {:event, %{type: :done, status: :completed, meta: %{}}}

    # Replay should not hit fake transport
    assert {:ok, _ref2} = Record.stream(req, callback)
    assert FakeTransport.calls(:stream) == 1

    assert_receive {:event, %{type: :delta, content: "chunk"}}
    assert_receive {:event, %{type: :done, status: :completed, meta: %{}}}
  end

  test "raises when prompts diverge", %{tmp: _tmp} do
    req = base_req(%{body: %{foo: "bar"}})
    assert {:ok, _} = Record.post(req)

    meta_path = Cassette.meta_path("record-demo")
    meta = meta_path |> File.read!() |> Jason.decode!()

    corrupt_meta = Map.put(meta, "body_hash", "different")
    File.write!(meta_path, Jason.encode!(corrupt_meta))

    assert_raise RuntimeError, ~r/Cassette prompt mismatch/, fn -> Record.post(req) end
  end

  defp base_req(overrides) do
    %{
      endpoint: :responses,
      url: "https://example",
      headers: [],
      body: %{},
      opts: [cassette: "record-demo", cassette_index: 1]
    }
    |> Map.merge(overrides)
  end
end
