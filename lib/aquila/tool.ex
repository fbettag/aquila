defmodule Aquila.Tool do
  @moduledoc """
  Representation of a callable tool/function exposed to a model.

  Tools wrap a function that receives decoded JSON arguments and returns a
  payload compatible with the Responses API tool-calling contract.
  """

  @enforce_keys [:name, :parameters, :fun]
  defstruct [:name, :description, :parameters, :fun]

  @typedoc "JSON-function definition used when exposing tools to the model."
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          parameters: map(),
          fun: (map() -> map() | String.t())
        }

  @doc """
  Creates a tool definition from a name, optional metadata, and a callback.

  The callback receives a map decoded from the JSON arguments sent by the
  model and should return a map or string response.

  ## Options

  * `:parameters` (required) – JSON Schema map describing the tool arguments.
  * `:description` – short description surfaced in the model prompt.
  """
  @spec new(String.t(), (map() -> any())) :: t()
  def new(name, fun) when is_function(fun, 1), do: new(name, [], fun)

  @spec new(String.t(), keyword(), (map() -> any())) :: t()
  def new(name, opts, fun) when is_binary(name) and is_function(fun, 1) do
    parameters =
      Keyword.get(opts, :parameters) ||
        raise ArgumentError, "tool requires :parameters (JSON schema map)"

    struct!(__MODULE__,
      name: name,
      description: Keyword.get(opts, :description),
      parameters: parameters,
      fun: fun
    )
  end

  @doc """
  Converts a tool definition into the wire-format map expected by OpenAI.

  Accepts either `%Aquila.Tool{}` structs or pre-normalised maps. Useful when you
  want to provide hand-crafted payloads for advanced tool types.
  """
  @spec to_openai(map() | t()) :: map()
  def to_openai(%__MODULE__{name: name, description: description, parameters: parameters}) do
    function =
      %{name: name, parameters: parameters}
      |> maybe_put(:description, description)

    %{type: "function", function: function}
  end

  def to_openai(%{type: type} = map) when is_atom(type) do
    map
    |> Map.put(:type, Atom.to_string(type))
    |> maybe_stringify_function_type()
  end

  def to_openai(%{type: type} = map) when is_binary(type) do
    maybe_stringify_function_type(map)
  end

  def to_openai(%{"type" => type} = map) when is_atom(type) do
    Map.put(map, "type", Atom.to_string(type))
  end

  def to_openai(%{"type" => type} = map) when is_binary(type), do: map

  defp maybe_stringify_function_type(%{type: type, function: function} = map) do
    updated_function =
      function
      |> Map.update(:name, nil, & &1)
      |> Map.update("name", nil, & &1)

    %{map | type: type, function: updated_function}
  end

  defp maybe_stringify_function_type(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
