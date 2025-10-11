defmodule Aquila.Transport.Cassette do
  @moduledoc false

  alias StableJason

  @type cassette :: String.t()
  @type index :: pos_integer()

  defp meta_table, do: :aquila_cassette_meta
  defp sse_table, do: :aquila_cassette_sse

  defp ensure_meta_table do
    case :ets.whereis(meta_table()) do
      :undefined ->
        :ets.new(meta_table(), [:set, :public, :named_table, {:read_concurrency, true}])

      _ref ->
        meta_table()
    end
  end

  defp ensure_meta_loaded(cassette, path) do
    table = ensure_meta_table()

    case :ets.lookup(table, {:loaded, cassette}) do
      [{_, {:ok, {cached_mtime, cached_size}}}] ->
        case File.stat(path) do
          {:ok, %File.Stat{mtime: ^cached_mtime, size: ^cached_size}} ->
            :ok

          {:ok, _stat} ->
            load_meta_cache(cassette, path)

          {:error, reason} ->
            reset_meta_cache(cassette)
            {:error, {:meta_missing, path, reason}}
        end

      [{_, :missing}] ->
        case File.stat(path) do
          {:ok, _stat} -> load_meta_cache(cassette, path)
          {:error, _reason} -> :missing
        end

      [] ->
        load_meta_cache(cassette, path)
    end
  end

  defp load_meta_cache(cassette, path) do
    reset_meta_cache(cassette)

    if File.exists?(path) do
      table = ensure_meta_table()

      result =
        path
        |> File.stream!([], :line)
        |> Enum.reduce_while(:ok, fn line, acc ->
          trimmed = String.trim(line)

          if trimmed == "" do
            {:cont, acc}
          else
            case Jason.decode(trimmed) do
              {:ok, %{"request_id" => request_id} = meta} ->
                :ets.insert(table, {{cassette, request_id}, meta})
                {:cont, acc}

              {:error, reason} ->
                {:halt, {:error, {:meta_decode_failed, path, reason}}}

              _ ->
                {:cont, acc}
            end
          end
        end)

      case result do
        :ok ->
          case File.stat(path) do
            {:ok, %File.Stat{mtime: mtime, size: size}} ->
              :ets.insert(table, {{:loaded, cassette}, {:ok, {mtime, size}}})
              :ok

            {:error, reason} ->
              {:error, {:meta_missing, path, reason}}
          end

        {:error, _reason} = error ->
          error
      end
    else
      table = ensure_meta_table()
      :ets.insert(table, {{:loaded, cassette}, :missing})
      :missing
    end
  end

  defp cache_meta_entry(cassette, request_id, meta) do
    table = ensure_meta_table()
    normalized = stringify_top_level_keys(meta)
    :ets.insert(table, {{cassette, request_id}, normalized})

    case File.stat(meta_path(cassette)) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        :ets.insert(table, {{:loaded, cassette}, {:ok, {mtime, size}}})

      {:error, _reason} ->
        :ets.delete(table, {:loaded, cassette})
    end

    :ok
  end

  defp ensure_sse_loaded(cassette, path) do
    table = ensure_sse_table()

    case :ets.lookup(table, {:loaded, cassette}) do
      [{_, {:ok, {cached_mtime, cached_size}}}] ->
        case File.stat(path) do
          {:ok, %File.Stat{mtime: ^cached_mtime, size: ^cached_size}} ->
            :ok

          {:ok, _stat} ->
            load_sse_cache(cassette, path)

          {:error, reason} ->
            reset_sse_cache(cassette)
            {:error, {:sse_missing, path, reason}}
        end

      [{_, :missing}] ->
        case File.stat(path) do
          {:ok, _stat} -> load_sse_cache(cassette, path)
          {:error, _reason} -> :missing
        end

      [] ->
        load_sse_cache(cassette, path)
    end
  end

  defp load_sse_cache(cassette, path) do
    reset_sse_cache(cassette)
    table = ensure_sse_table()

    if File.exists?(path) do
      result =
        path
        |> File.stream!([], :line)
        |> Enum.reduce_while(:ok, fn line, acc ->
          trimmed = String.trim(line)

          if trimmed == "" do
            {:cont, acc}
          else
            case Jason.decode(trimmed) do
              {:ok, %{"request_id" => request_id}} ->
                :ets.insert(table, {{cassette, request_id}, true})
                {:cont, acc}

              {:error, reason} ->
                {:halt, {:error, {:sse_decode_failed, path, reason}}}

              _ ->
                {:cont, acc}
            end
          end
        end)

      case result do
        :ok ->
          case File.stat(path) do
            {:ok, %File.Stat{mtime: mtime, size: size}} ->
              :ets.insert(table, {{:loaded, cassette}, {:ok, {mtime, size}}})
              :ok

            {:error, reason} ->
              {:error, {:sse_missing, path, reason}}
          end

        {:error, _reason} = error ->
          error
      end
    else
      :ets.insert(table, {{:loaded, cassette}, :missing})
      :missing
    end
  end

  @doc false
  @spec cache_sse_request(cassette(), index()) :: :ok
  def cache_sse_request(cassette, request_id) do
    table = ensure_sse_table()
    :ets.insert(table, {{cassette, request_id}, true})

    case File.stat(sse_path(cassette)) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        :ets.insert(table, {{:loaded, cassette}, {:ok, {mtime, size}}})

      {:error, _reason} ->
        :ets.delete(table, {:loaded, cassette})
    end

    :ok
  end

  defp reset_meta_cache(:all) do
    case :ets.whereis(meta_table()) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp reset_meta_cache(cassette) do
    case :ets.whereis(meta_table()) do
      :undefined ->
        :ok

      table ->
        :ets.match_delete(table, {{cassette, :_}, :_})
        :ets.delete(table, {:loaded, cassette})
        :ok
    end
  end

  defp reset_sse_cache(:all) do
    case :ets.whereis(sse_table()) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp reset_sse_cache(cassette) do
    case :ets.whereis(sse_table()) do
      :undefined ->
        :ok

      table ->
        :ets.match_delete(table, {{cassette, :_}, :_})
        :ets.delete(table, {:loaded, cassette})
        :ok
    end
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {canonical_key(key), value} end)
    |> Enum.into(%{})
  end

  defp ensure_sse_table do
    case :ets.whereis(sse_table()) do
      :undefined ->
        :ets.new(sse_table(), [:set, :public, :named_table, {:read_concurrency, true}])

      _ref ->
        sse_table()
    end
  end

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

    case what do
      :meta ->
        File.exists?(path) and match?({:ok, _}, read_meta(cassette, index))

      :sse ->
        sse_exists?(cassette, index, path)

      :post ->
        File.exists?(path)
    end
  end

  defp sse_exists?(cassette, request_id, path) do
    table = ensure_sse_table()
    key = {cassette, request_id}

    case :ets.lookup(table, key) do
      [{^key, true}] ->
        true

      [] ->
        case ensure_sse_loaded(cassette, path) do
          :ok ->
            match?([{^key, true}], :ets.lookup(table, key))

          :missing ->
            false

          {:error, _reason} ->
            false
        end
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

    reset_meta_cache(:all)
    reset_sse_cache(:all)

    :ok
  end

  def reset_index(cassette) do
    case :ets.whereis(:aquila_cassette_indices) do
      :undefined -> :ok
      _ref -> :ets.delete(:aquila_cassette_indices, cassette)
    end

    reset_meta_cache(cassette)
    reset_sse_cache(cassette)

    :ok
  end

  @spec write_meta(cassette(), index(), map()) :: :ok
  def write_meta(cassette, request_id, meta) do
    path = meta_path(cassette)
    ensure_dir(path)

    meta_with_id = Map.put(meta, "request_id", request_id)
    line = StableJason.encode!(meta_with_id, sorter: :asc) <> "\n"

    File.write!(path, line, [:append])
    cache_meta_entry(cassette, request_id, meta_with_id)
  end

  @spec read_meta(cassette(), index()) :: {:ok, map()} | {:error, term()}
  def read_meta(cassette, request_id) do
    table = ensure_meta_table()
    key = {cassette, request_id}

    path = meta_path(cassette)

    case ensure_meta_loaded(cassette, path) do
      :ok ->
        case :ets.lookup(table, key) do
          [{^key, meta}] ->
            {:ok, meta}

          [] ->
            {:error, {:meta_missing, path, :not_found}}
        end

      :missing ->
        {:error, {:meta_missing, path, :not_found}}

      {:error, reason} ->
        {:error, reason}
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
