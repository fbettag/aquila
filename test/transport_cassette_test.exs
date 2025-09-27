defmodule Aquila.TransportCassetteTest do
  use ExUnit.Case, async: true

  alias Aquila.Transport.Cassette

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "aquila-cassette-test-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp)

    original = Application.get_env(:aquila, :recorder, [])
    Application.put_env(:aquila, :recorder, Keyword.put(original, :path, tmp))

    on_exit(fn ->
      Application.put_env(:aquila, :recorder, original)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  test "next_index increments per process" do
    assert Cassette.next_index("demo") == 1
    assert Cassette.next_index("demo") == 2

    spawn(fn -> assert Cassette.next_index("demo") == 1 end)
  end

  test "write_meta and read_meta roundtrip", %{tmp: tmp} do
    meta = %{foo: "bar"}
    Cassette.write_meta("demo", 1, meta)

    assert {:ok, %{"foo" => "bar"}} = Cassette.read_meta("demo", 1)
    assert Cassette.exists?("demo", 1, :meta)

    assert Cassette.meta_path("demo", 1) |> String.starts_with?(tmp)
  end

  test "canonical_hash normalises structures" do
    a = %{a: 1, b: [2, 3]}
    b = %{"b" => [2, 3], "a" => 1}

    assert Cassette.canonical_hash(a) == Cassette.canonical_hash(b)
  end
end
