defmodule Aquila.Transport.Cassette do
  @moduledoc false

  @type cassette :: String.t()
  @type index :: pos_integer()

  @spec base_path() :: String.t()
  def base_path do
    Application.get_env(:aquila, :recorder, [])
    |> Keyword.get(:path, "test/support/cassettes")
  end

  @spec meta_path(cassette(), index()) :: String.t()
  def meta_path(name, index), do: Path.join(base_path(), "#{name}-#{index}.meta.json")

  @spec sse_path(cassette(), index()) :: String.t()
  def sse_path(name, index), do: Path.join(base_path(), "#{name}-#{index}.sse.jsonl")

  @spec post_path(cassette(), index()) :: String.t()
  def post_path(name, index), do: Path.join(base_path(), "#{name}-#{index}.json")

  @spec exists?(cassette(), index(), :meta | :sse | :post) :: boolean()
  def exists?(cassette, index, what) do
    path =
      case what do
        :meta -> meta_path(cassette, index)
        :sse -> sse_path(cassette, index)
        :post -> post_path(cassette, index)
      end

    File.exists?(path)
  end

  @spec next_index(cassette(), keyword()) :: index()
  def next_index(cassette, opts \\ []) do
    case Keyword.get(opts, :cassette_index) do
      nil ->
        key = {:aquila_cassette_index, cassette}
        idx = Process.get(key, 0) + 1
        Process.put(key, idx)
        idx

      index when is_integer(index) and index > 0 ->
        index
    end
  end

  @spec write_meta(cassette(), index(), map()) :: :ok
  def write_meta(cassette, index, meta) do
    path = meta_path(cassette, index)
    ensure_dir(path)
    File.write!(path, Jason.encode_to_iodata!(meta, pretty: true))
  end

  @spec read_meta(cassette(), index()) :: {:ok, map()} | {:error, term()}
  def read_meta(cassette, index) do
    path = meta_path(cassette, index)

    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      {:error, reason} -> {:error, {:meta_missing, path, reason}}
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
