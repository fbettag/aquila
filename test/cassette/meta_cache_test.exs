defmodule Aquila.CassetteMetaCacheTest do
  use ExUnit.Case, async: false

  alias Aquila.Transport.Cassette

  @cassette_dir Cassette.base_path()

  setup do
    cassette = "meta_cache_#{System.unique_integer([:positive])}"
    meta_path = Cassette.meta_path(cassette)

    File.mkdir_p!(@cassette_dir)

    on_exit(fn ->
      File.rm(meta_path)
    end)

    {:ok, cassette: cassette, meta_path: meta_path}
  end

  test "write_meta caches entry in ets and persists to disk", %{
    cassette: cassette,
    meta_path: meta_path
  } do
    # minimal payload that will be stringified by cache_meta_entry
    meta = %{
      "foo" => "bar",
      "nested" => %{"value" => 1}
    }

    assert :ok = Cassette.write_meta(cassette, 1, meta)

    assert File.exists?(meta_path)

    assert {:ok, stored} = Cassette.read_meta(cassette, 1)
    assert stored["foo"] == "bar"
    assert stored["nested"] == %{"value" => 1}
    assert stored["request_id"] == 1
  end
end
