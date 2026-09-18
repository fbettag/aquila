defmodule Aquila.TypeSafe.Model do
  @moduledoc "A model or alias returned by the TypeSafe models endpoint."

  @enforce_keys [:name, :description, :release_date]
  defstruct [:name, :description, :release_date]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          release_date: String.t()
        }
end
