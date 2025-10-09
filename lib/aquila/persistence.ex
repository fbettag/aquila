defmodule Aquila.Persistence do
  @moduledoc """
  Behaviour for persisting chat messages and streaming state.

  Implementations of this behaviour can hook into the streaming lifecycle
  to save messages to a database, file system, or any other storage backend.

  ## Lifecycle Callbacks

  The callbacks are invoked in the following order during a streaming session:

  1. `on_start/3` - Called when streaming begins, before any chunks arrive
  2. `on_chunk/4` - Called for each chunk of the streaming response
  3. `on_complete/4` - Called when streaming completes successfully
  4. `on_error/4` - Called if streaming encounters an error
  5. `on_tool_call/5` - Called when a tool is executed (optional)
  6. `on_event/5` - Called for additional streaming events such as Deep Research updates (optional)

  ## State Management

  Each callback receives a `state` map that can be used to track persistence-specific
  information (like database IDs, counters, etc.). The state is threaded through
  all callbacks in the lifecycle.

  ## Example

      defmodule MyApp.ChatPersistence do
        @behaviour Aquila.Persistence

        @impl true
        def on_start(session_id, content, opts) do
          # Create user message in database
          user_id = Keyword.fetch!(opts, :user_id)
          {:ok, message} = create_message(session_id, :user, content, user_id)
          {:ok, %{user_message_id: message.id}}
        end

        @impl true
        def on_chunk(session_id, chunk, state, opts) do
          # Optionally save intermediate chunks
          {:ok, Map.update(state, :accumulated, chunk, &(&1 <> chunk))}
        end

        @impl true
        def on_complete(session_id, full_text, state, opts) do
          # Save final assistant message
          user_id = Keyword.fetch!(opts, :user_id)
          {:ok, _message} = create_message(session_id, :assistant, full_text, user_id)
          :ok
        end

        @impl true
        def on_error(session_id, error, state, opts) do
          # Log error, cleanup if needed
          :ok
        end
      end
  """

  @doc """
  Called when a streaming session starts.

  This is invoked before any chunks arrive, allowing you to create initial
  database records or prepare storage.

  Returns `{:ok, state}` with initial state, or `{:error, reason}` to abort.
  """
  @callback on_start(session_id :: term(), content :: String.t(), opts :: keyword()) ::
              {:ok, state :: map()} | {:error, term()}

  @doc """
  Called for each chunk during streaming.

  Chunks arrive incrementally as the AI generates the response. You can use
  this to update progress, save intermediate states, or accumulate text.

  Returns `{:ok, new_state}` to continue, or `{:error, reason}` to abort.
  """
  @callback on_chunk(
              session_id :: term(),
              chunk :: String.t(),
              state :: map(),
              opts :: keyword()
            ) ::
              {:ok, new_state :: map()} | {:error, term()}

  @doc """
  Called when streaming completes successfully.

  The `full_text` parameter contains the complete response text.

  Returns `:ok` on success, or `{:error, reason}` if finalization fails.
  """
  @callback on_complete(
              session_id :: term(),
              full_text :: String.t(),
              state :: map(),
              opts :: keyword()
            ) ::
              :ok | {:error, term()}

  @doc """
  Called when streaming encounters an error.

  This allows you to log errors, cleanup resources, or save partial state.

  Returns `:ok` - errors during this callback are logged but don't affect the stream.
  """
  @callback on_error(
              session_id :: term(),
              error :: term(),
              state :: map(),
              opts :: keyword()
            ) ::
              :ok

  @doc """
  Called when a tool is executed during the streaming session.

  This optional callback allows you to log tool executions or store them
  separately from the main conversation.

  Returns `{:ok, new_state}` to continue, or `{:error, reason}` to abort.
  """
  @callback on_tool_call(
              session_id :: term(),
              tool_name :: String.t(),
              result :: term(),
              state :: map(),
              opts :: keyword()
            ) ::
              {:ok, new_state :: map()} | {:error, term()}

  @doc """
  Called when additional streaming events are emitted (e.g. Deep Research progress).

  Implementations can return:

    * `{:ok, new_state}` to update the persistence state
    * `:ok` to leave the state unchanged
    * `{:error, reason}` to signal a persistence failure (logged and ignored)
  """
  @callback on_event(
              session_id :: term(),
              event_category :: atom(),
              event :: map(),
              state :: map(),
              opts :: keyword()
            ) ::
              {:ok, new_state :: map()} | :ok | {:error, term()}

  @optional_callbacks on_tool_call: 5, on_event: 5
end
