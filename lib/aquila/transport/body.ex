defmodule Aquila.Transport.Body do
  @moduledoc false

  alias Aquila.Transport.Cassette
  alias StableJason

  @context_lines 3
  @max_diff_lines 200

  @doc """
  Normalises the request body so that maps and lists have stable ordering and
  atoms are converted into strings. Raw binaries are decoded when they contain
  JSON payloads.
  """
  def normalize(nil), do: nil

  def normalize(body) when is_map(body) or is_list(body) do
    body
    |> StableJason.encode!(sorter: :asc)
    |> Jason.decode!()
  end

  def normalize(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        normalize(decoded)

      _ ->
        body
    end
  end

  def normalize(body), do: body

  @doc """
  Returns true when the two bodies are structurally equivalent once
  normalised.
  """
  def equivalent?(recorded, current) do
    canonical(recorded) == canonical(current)
  end

  @doc """
  Produces a compact, human-readable diff between two request bodies.
  """
  def diff(recorded, current) do
    recorded_lines = encode_lines(recorded)
    current_lines = encode_lines(current)

    lines =
      recorded_lines
      |> List.myers_difference(current_lines)
      |> annotate_lines()
      |> trim_context()

    {kept, discarded} = Enum.split(lines, @max_diff_lines)

    kept =
      if discarded == [] do
        kept
      else
        kept ++ [{:eq, "  …diff truncated…"}]
      end

    kept
    |> Enum.map(&elem(&1, 1))
    |> Enum.join("\n")
  end

  defp canonical(nil), do: Cassette.canonical_term(:no_body)

  defp canonical(body) do
    body
    |> normalize()
    |> reorder_lists()
    |> Cassette.canonical_term()
  end

  defp encode_lines(body) do
    body
    |> normalize()
    |> reorder_lists()
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
  end

  defp annotate_lines(diff) do
    Enum.flat_map(diff, fn
      {:eq, lines} -> Enum.map(lines, &{:eq, "  " <> &1})
      {:del, lines} -> Enum.map(lines, &{:del, "- " <> &1})
      {:ins, lines} -> Enum.map(lines, &{:ins, "+ " <> &1})
    end)
  end

  defp trim_context(lines) do
    lines
    |> trim_leading_eq()
    |> trim_trailing_eq()
  end

  defp trim_leading_eq(lines) do
    {leading, rest} = Enum.split_while(lines, fn {tag, _} -> tag == :eq end)

    case rest do
      [] ->
        take_last(leading, @context_lines)

      _ ->
        take_last(leading, @context_lines) ++ rest
    end
  end

  defp trim_trailing_eq(lines) do
    lines
    |> Enum.reverse()
    |> trim_leading_eq()
    |> Enum.reverse()
  end

  defp take_last(_list, count) when count <= 0, do: []

  defp take_last(list, count) do
    length = Enum.count(list)
    drop = max(length - count, 0)
    Enum.drop(list, drop)
  end

  defp reorder_lists(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {k, reorder_lists(v)} end)
  end

  defp reorder_lists(term) when is_list(term) do
    term
    |> Enum.map(&reorder_lists/1)
    |> maybe_sort_list()
  end

  defp reorder_lists(term), do: term

  defp maybe_sort_list(list) do
    if Enum.all?(list, &scalar?/1) do
      Enum.sort_by(list, &scalar_sort_key/1)
    else
      list
    end
  end

  defp scalar?(value) when is_binary(value), do: true
  defp scalar?(value) when is_number(value), do: true
  defp scalar?(value) when is_boolean(value), do: true
  defp scalar?(nil), do: true
  defp scalar?(_), do: false

  defp scalar_sort_key(nil), do: {nil, ""}
  defp scalar_sort_key(value) when is_binary(value), do: {:string, value}
  defp scalar_sort_key(value) when is_number(value), do: {:number, value}
  defp scalar_sort_key(value) when is_boolean(value), do: {:boolean, value}
end
