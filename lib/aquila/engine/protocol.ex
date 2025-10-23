defmodule Aquila.Engine.Protocol do
  @moduledoc """
  Protocol defining the interface that Chat and Responses engines must implement.

  This allows the main Engine module to delegate endpoint-specific behavior
  while maintaining a consistent internal API.
  """

  @doc """
  Builds the API URL for this endpoint.

  Returns a string URL (e.g., "https://api.openai.com/v1/chat/completions").
  """
  @callback build_url(state :: map()) :: String.t()

  @doc """
  Builds the request body for this endpoint.

  Returns a map that will be JSON-encoded for the HTTP POST request.
  The second parameter indicates whether streaming is enabled.
  """
  @callback build_body(state :: map(), stream? :: boolean()) :: map()

  @doc """
  Appends a tool output message to the messages list.

  For Chat API: appends a function or tool role message.
  For Responses API: returns messages unchanged (tool outputs handled separately).

  Returns the updated messages list.
  """
  @callback append_tool_output_message(
              state :: map(),
              messages :: list(),
              call :: map(),
              output :: any()
            ) :: list()

  @doc """
  Updates state after tool execution with endpoint-specific output handling.

  For Chat API: updates messages list.
  For Responses API: updates tool_payloads list.

  Returns the updated state.
  """
  @callback handle_tool_outputs(
              state :: map(),
              payloads :: list(),
              messages :: list(),
              tool_context :: any(),
              tool_outputs :: list(),
              call_history :: list()
            ) :: map()

  @doc """
  Appends assistant message with tool call information if needed.

  For Chat API: appends assistant message with tool_calls field.
  For Responses API: returns messages unchanged.

  Returns the updated messages list.
  """
  @callback maybe_append_assistant_tool_call(
              state :: map(),
              messages :: list(),
              call :: map()
            ) :: list()

  @doc """
  Rebuilds tool messages after detecting format/role incompatibility.

  The second parameter is either:
  - {:format, :text | :tool_result} for tool message format retry
  - {:role, boolean()} for role compatibility retry (true = tool role, false = function role)

  Returns the updated state with rebuilt messages.
  """
  @callback rebuild_tool_messages_for_retry(
              state :: map(),
              format_or_role_flag :: {:format, atom()} | {:role, boolean()}
            ) :: map()
end
