defmodule Aquila.TypeSafe.Question do
  @moduledoc """
  Typed question constructors for TypeSafe System One models.

  A question is evaluated independently against the request state. Use
  `choice/2` for one outcome from a closed set, `score/2` for an ordered
  rubric, and `noul/2` for the probability that a condition holds.
  """

  @enforce_keys [:type, :instructions]
  defstruct [:type, :instructions, :criteria]

  @type instruction :: String.t() | map() | list()
  @type t :: %__MODULE__{
          type: :choice | :score | :noul,
          instructions: instruction(),
          criteria: map() | list() | nil
        }

  @doc "Builds a closed-set choice question."
  @spec choice(instruction(), map()) :: t()
  def choice(instructions, criteria) do
    validate_instructions!(instructions)

    unless is_map(criteria) and map_size(criteria) >= 2 do
      raise ArgumentError, "choice criteria must be a map with at least two options"
    end

    %__MODULE__{type: :choice, instructions: instructions, criteria: criteria}
  end

  @doc "Builds an ordered score question."
  @spec score(instruction(), list()) :: t()
  def score(instructions, criteria) do
    validate_instructions!(instructions)

    unless is_list(criteria) and length(criteria) >= 2 do
      raise ArgumentError, "score criteria must be an ordered list with at least two levels"
    end

    %__MODULE__{type: :score, instructions: instructions, criteria: criteria}
  end

  @doc "Builds a yes/no probability question."
  @spec noul(instruction(), map() | nil) :: t()
  def noul(instructions, criteria \\ nil) do
    validate_instructions!(instructions)
    criteria = normalize_noul_criteria!(criteria)
    %__MODULE__{type: :noul, instructions: instructions, criteria: criteria}
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = question) do
    %{
      "type" => Atom.to_string(question.type),
      "instructions" => question.instructions
    }
    |> maybe_put("criteria", question.criteria)
  end

  defp validate_instructions!(value)
       when (is_binary(value) and value != "") or (is_map(value) and map_size(value) > 0) or
              (is_list(value) and value != []),
       do: :ok

  defp validate_instructions!(_value) do
    raise ArgumentError, "question instructions must be a non-empty string, map, or list"
  end

  defp normalize_noul_criteria!(nil), do: nil

  defp normalize_noul_criteria!(criteria) when is_map(criteria) do
    true_value = Map.get(criteria, true) || Map.get(criteria, "true")
    false_value = Map.get(criteria, false) || Map.get(criteria, "false")

    if is_nil(true_value) or is_nil(false_value) do
      raise ArgumentError, "noul criteria must define both true and false descriptions"
    end

    %{"true" => true_value, "false" => false_value}
  end

  defp normalize_noul_criteria!(_criteria) do
    raise ArgumentError, "noul criteria must be a map defining true and false descriptions"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
