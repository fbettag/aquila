defmodule Aquila.CassetteTest do
  use ExUnit.Case, async: true

  alias Aquila.Transport.Cassette

  test "canonical_term normalises temporal structs" do
    datetime = DateTime.utc_now() |> DateTime.truncate(:second)
    naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    time = Time.utc_now() |> Time.truncate(:second)

    assert {:datetime, DateTime.to_iso8601(datetime)} == Cassette.canonical_term(datetime)
    assert {:naive_datetime, NaiveDateTime.to_iso8601(naive)} == Cassette.canonical_term(naive)
    assert {:time, Time.to_iso8601(time)} == Cassette.canonical_term(time)
  end

  test "canonical_term handles tuples and lists" do
    tuple = {:ok, [1, %{foo: :bar}]}
    {:ok, [1, canonical_map]} = Cassette.canonical_term(tuple)
    assert {"foo", :bar} in canonical_map
  end

  test "canonical_key falls back to inspect" do
    assert Cassette.canonical_key(123) == "123"
  end
end
