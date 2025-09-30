defmodule Aquila.Transport.Cassette do
  @moduledoc false

  alias StableJason

  @type cassette :: String.t()
  @type index :: pos_integer()

  @spec base_path() :: String.t()
  def base_path do
    Application.get_env(:aquila, :recorder, [])
    |> Keyword.get(:path, "test/support/fixtures/aquila_cassettes")
  end

  @spec meta_path(cassette()) :: String.t()
  def meta_path(name), do: Path.join(base_path(), "#{name}.meta.jsonl")

  @spec sse_path(cassette()) :: String.t()
  def sse_path(name), do: Path.join(base_path(), "#{name}.sse.jsonl")

  @spec post_path(cassette(), index()) :: String.t()
  def post_path(name, index), do: Path.join(base_path(), "#{name}-#{index}.json")

  @spec exists?(cassette(), index(), :meta | :sse | :post) :: boolean()
  def exists?(cassette, index, what) do
    path =
      case what do
        :meta -> meta_path(cassette)
        :sse -> sse_path(cassette)
        :post -> post_path(cassette, index)
      end

    if what in [:meta, :sse] do
      File.exists?(path) and has_request_id?(path, index)
    else
      File.exists?(path)
    end
  end

  defp has_request_id?(path, request_id) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case Jason.decode(line) do
            {:ok, %{"request_id" => ^request_id}} -> true
            _ -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  @spec next_index(cassette(), keyword()) :: index()
  def next_index(cassette, opts \\ []) do
    case Keyword.get(opts, :cassette_index) do
      nil ->
        # Ensure ETS table exists
        table = ensure_ets_table()

        # Use update_counter for atomic increment
        # update_counter returns the NEW value after increment
        # Default value is 0, so first increment returns 1
        :ets.update_counter(table, cassette, {2, 1}, {cassette, 0})

      index when is_integer(index) and index > 0 ->
        index
    end
  end

  defp ensure_ets_table do
    table_name = :aquila_cassette_indices

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:set, :public, :named_table])

      _ref ->
        table_name
    end
  end

  @doc """
  Resets the cassette index counter for a specific cassette or all cassettes.

  Used in test setup to ensure clean state between test runs.
  """
  @spec reset_index(cassette() | :all) :: :ok
  def reset_index(:all) do
    case :ets.whereis(:aquila_cassette_indices) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(:aquila_cassette_indices)
    end

    :ok
  end

  def reset_index(cassette) do
    case :ets.whereis(:aquila_cassette_indices) do
      :undefined -> :ok
      _ref -> :ets.delete(:aquila_cassette_indices, cassette)
    end

    :ok
  end

  @spec write_meta(cassette(), index(), map()) :: :ok
  def write_meta(cassette, request_id, meta) do
    path = meta_path(cassette)
    ensure_dir(path)

    meta_with_id = Map.put(meta, "request_id", request_id)
    line = StableJason.encode!(meta_with_id, sorter: :asc) <> "\n"

    File.write!(path, line, [:append])
  end

  @spec read_meta(cassette(), index()) :: {:ok, map()} | {:error, term()}
  def read_meta(cassette, request_id) do
    path = meta_path(cassette)

    case File.read(path) do
      {:ok, content} ->
        result =
          content
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case Jason.decode(line) do
              {:ok, %{"request_id" => ^request_id} = meta} -> {:ok, meta}
              _ -> nil
            end
          end)

        result || {:error, {:meta_missing, path, :not_found}}

      {:error, reason} ->
        {:error, {:meta_missing, path, reason}}
    end
  end

  @spec ensure_dir(String.t()) :: :ok
  def ensure_dir(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :ok
  end

  @spec canonical_hash(term()) :: String.t()
  def canonical_hash(term) do
    term
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec canonical_term(term()) :: term()
  def canonical_term(%DateTime{} = dt), do: {:datetime, DateTime.to_iso8601(dt)}
  def canonical_term(%NaiveDateTime{} = ndt), do: {:naive_datetime, NaiveDateTime.to_iso8601(ndt)}
  def canonical_term(%Time{} = time), do: {:time, Time.to_iso8601(time)}

  def canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {canonical_key(k), canonical_term(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  def canonical_term(list) when is_list(list) do
    Enum.map(list, &canonical_term/1)
  end

  def canonical_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&canonical_term/1)
    |> List.to_tuple()
  end

  def canonical_term(other), do: other

  @spec canonical_key(term()) :: String.t()
  def canonical_key(atom) when is_atom(atom), do: Atom.to_string(atom)
  def canonical_key(binary) when is_binary(binary), do: binary
  def canonical_key(other), do: inspect(other)
end
