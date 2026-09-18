defmodule Aquila.TypeSafe.Answer.Choice do
  @moduledoc "A typed closed-set answer returned by a TypeSafe System One model."

  @enforce_keys [:choice, :probabilities, :confidence]
  defstruct type: :choice, choice: nil, probabilities: %{}, confidence: nil

  @type t :: %__MODULE__{
          type: :choice,
          choice: String.t(),
          probabilities: %{String.t() => float()},
          confidence: float()
        }
end

defmodule Aquila.TypeSafe.Answer.Score do
  @moduledoc "A typed ordered-rubric answer returned by a TypeSafe System One model."

  @enforce_keys [:score, :legend, :probabilities, :confidence]
  defstruct type: :score, score: nil, legend: %{}, probabilities: %{}, confidence: nil

  @type t :: %__MODULE__{
          type: :score,
          score: float(),
          legend: %{String.t() => term()},
          probabilities: %{String.t() => float()},
          confidence: float()
        }
end

defmodule Aquila.TypeSafe.Answer.Noul do
  @moduledoc "A typed yes-probability answer returned by a TypeSafe System One model."

  @enforce_keys [:probability]
  defstruct type: :noul, probability: nil

  @type t :: %__MODULE__{type: :noul, probability: float()}
end

defmodule Aquila.TypeSafe.Answer do
  @moduledoc "Common type and response parser for TypeSafe answer variants."

  alias Aquila.TypeSafe.Answer.{Choice, Noul, Score}

  @type t :: Choice.t() | Score.t() | Noul.t()

  @doc false
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(answer) when is_map(answer) do
    case value(answer, "type") do
      "choice" -> parse_choice(answer)
      "score" -> parse_score(answer)
      "noul" -> parse_noul(answer)
      other -> {:error, {:unknown_answer_type, other}}
    end
  end

  def parse(answer), do: {:error, {:invalid_answer, answer}}

  defp parse_choice(answer) do
    with choice when is_binary(choice) <- value(answer, "choice"),
         {:ok, probabilities} <- probability_map(value(answer, "probabilities")),
         {:ok, confidence} <- probability(value(answer, "confidence")) do
      {:ok, %Choice{choice: choice, probabilities: probabilities, confidence: confidence}}
    else
      _invalid -> {:error, {:invalid_choice_answer, answer}}
    end
  end

  defp parse_score(answer) do
    with {:ok, score} <- number(value(answer, "score")),
         legend when is_map(legend) <- value(answer, "legend"),
         {:ok, probabilities} <- probability_map(value(answer, "probabilities")),
         {:ok, confidence} <- probability(value(answer, "confidence")) do
      {:ok,
       %Score{
         score: score,
         legend: stringify_keys(legend),
         probabilities: probabilities,
         confidence: confidence
       }}
    else
      _invalid -> {:error, {:invalid_score_answer, answer}}
    end
  end

  defp parse_noul(answer) do
    case probability(value(answer, "noul")) do
      {:ok, probability} -> {:ok, %Noul{probability: probability}}
      _invalid -> {:error, {:invalid_noul_answer, answer}}
    end
  end

  defp probability_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case probability(value) do
        {:ok, probability} -> {:cont, {:ok, Map.put(acc, to_string(key), probability)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp probability_map(_map), do: :error

  defp probability(value) do
    with {:ok, number} <- number(value), true <- number >= 0.0 and number <= 1.0 do
      {:ok, number}
    else
      _invalid -> :error
    end
  end

  defp number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp number(value) when is_float(value), do: {:ok, value}
  defp number(_value), do: :error

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
