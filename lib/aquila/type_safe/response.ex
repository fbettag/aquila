defmodule Aquila.TypeSafe.Response do
  @moduledoc """
  Typed result from a TypeSafe System One evaluation.

  `model` is the versioned model that actually handled the request. `answers`
  is keyed by the caller-provided question IDs, and `raw` preserves the full
  provider response for diagnostics and forward-compatible access.
  """

  alias Aquila.TypeSafe.Answer

  @enforce_keys [:model, :answers, :usage, :raw]
  defstruct [:model, :answers, :usage, :raw]

  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{String.t() => Answer.t()},
          usage: map(),
          raw: map()
        }
end
