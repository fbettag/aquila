defmodule Aquila.StreamSession do
  @moduledoc """
  Supervised streaming session that broadcasts events via PubSub.

  This module wraps Aquila's streaming API in a supervised Task that broadcasts
  streaming events to subscribers via Phoenix.PubSub. It integrates with the
  `Aquila.Persistence` behaviour to save messages as they stream.

  ## Usage

      {:ok, pid} = Aquila.StreamSession.start(
        supervisor: MyApp.TaskSupervisor,
        pubsub: MyApp.PubSub,
        session_id: "thread-123",
        assistant: assistant_struct,
        content: "User message content",
        persistence: MyApp.ChatPersistence,
        persistence_opts: [user_id: user.id],
        on_complete: fn -> IO.puts("Done!") end
      )

  ## PubSub Events

  Subscribers to `"aquila:session:\#{session_id}"` will receive:

  - `{:aquila_stream_delta, session_id, text}` - Each chunk of streaming text
  - `{:aquila_stream_tool_call, session_id, tool_name, result}` - Tool execution results
  - `{:aquila_stream_usage, session_id, usage}` - Token usage information
  - `{:aquila_stream_complete, session_id}` - Streaming completed successfully
  - `{:aquila_stream_error, session_id, reason}` - Streaming encountered an error

  ## Options

  - `:supervisor` - Required. The Task.Supervisor to use for the streaming task
  - `:pubsub` - Required. The PubSub module to broadcast events through
  - `:session_id` - Required. Unique identifier for this streaming session
  - `:assistant` - Required. Aquila.Assistant struct with instructions/tools
  - `:content` - Required. The user message content (string or content parts)
  - `:persistence` - Optional. Module implementing `Aquila.Persistence` behaviour
  - `:persistence_opts` - Optional. Options passed to persistence callbacks
  - `:on_complete` - Optional. Function called when streaming completes
  - `:timeout` - Optional. Timeout for the streaming request (default: 120_000ms)
  """

  require Logger

  # Ensure Phoenix.PubSub is compiled (optional dependency)
  _ = Code.ensure_loaded(Phoenix.PubSub)
  @default_timeout 120_000

  @doc """
  Starts a supervised streaming session.

  Returns `{:ok, pid}` where pid is the supervised task process.
  """
  def start(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    pubsub = Keyword.fetch!(opts, :pubsub)
    session_id = Keyword.fetch!(opts, :session_id)
    assistant = Keyword.fetch!(opts, :assistant)
    content = Keyword.fetch!(opts, :content)

    persistence = Keyword.get(opts, :persistence)
    persistence_opts = Keyword.get(opts, :persistence_opts, [])
    on_complete = Keyword.get(opts, :on_complete)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Task.Supervisor.start_child(supervisor, fn ->
      handle_stream_loop(
        pubsub,
        session_id,
        assistant,
        content,
        persistence,
        persistence_opts,
        on_complete,
        timeout
      )
    end)
  end

  defp handle_stream_loop(
         pubsub,
         session_id,
         assistant,
         content,
         persistence,
         persistence_opts,
         on_complete,
         timeout
       ) do
    # Initialize persistence state
    persistence_state = initialize_persistence(persistence, session_id, content, persistence_opts)

    # Build messages for Aquila - include conversation history from assistant
    messages = (assistant.messages || []) ++ [%{role: :user, content: content}]

    # Start streaming
    {:ok, ref} =
      Aquila.stream(messages,
        instructions: assistant.instructions,
        tools: assistant.tools || [],
        model: assistant.model,
        temperature: assistant.temperature,
        tool_context: assistant.context,
        timeout: timeout
      )

    # Process stream events
    Logger.info("Stream session started", session_id: session_id)

    handle_stream_events(
      ref,
      pubsub,
      session_id,
      persistence,
      persistence_state,
      persistence_opts,
      on_complete,
      "",
      timeout
    )
  end

  defp initialize_persistence(nil, _session_id, _content, _opts), do: %{}

  defp initialize_persistence(persistence_module, session_id, content, opts) do
    # Pass the full content (including files/images) to persistence, not just extracted text
    case persistence_module.on_start(session_id, content, opts) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("Persistence initialization failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        %{}
    end
  end

  defp handle_stream_events(
         ref,
         pubsub,
         session_id,
         persistence,
         state,
         p_opts,
         on_complete,
         accumulated,
         timeout
       ) do
    receive do
      {:aquila_chunk, chunk, ^ref} ->
        # Broadcast chunk
        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_delta,
          session_id,
          chunk
        })

        # Update persistence
        new_state = handle_chunk(persistence, session_id, chunk, state, p_opts)
        new_accumulated = accumulated <> chunk

        # Continue processing
        handle_stream_events(
          ref,
          pubsub,
          session_id,
          persistence,
          new_state,
          p_opts,
          on_complete,
          new_accumulated,
          timeout
        )

      {:aquila_tool_call, :start, metadata, ^ref} ->
        # Broadcast tool call start
        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_tool_call,
          session_id,
          :start,
          metadata
        })

        # Continue processing
        handle_stream_events(
          ref,
          pubsub,
          session_id,
          persistence,
          state,
          p_opts,
          on_complete,
          accumulated,
          timeout
        )

      {:aquila_tool_call, :result, metadata, ^ref} ->
        # Broadcast tool call result
        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_tool_call,
          session_id,
          :end,
          metadata
        })

        # Update persistence
        tool_name = Map.get(metadata, :name)
        output = Map.get(metadata, :output)
        new_state = handle_tool_call(persistence, session_id, tool_name, output, state, p_opts)

        # Continue processing
        handle_stream_events(
          ref,
          pubsub,
          session_id,
          persistence,
          new_state,
          p_opts,
          on_complete,
          accumulated,
          timeout
        )

      {:aquila_done, text, meta, ^ref} ->
        Logger.info("Stream session completed", session_id: session_id)
        # Broadcast usage if present
        if usage = meta[:usage] do
          Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
            :aquila_stream_usage,
            session_id,
            usage
          })
        end

        # Finalize persistence
        handle_complete(persistence, session_id, text, state, p_opts)

        # Call on_complete callback
        if is_function(on_complete, 0), do: on_complete.()

        # Broadcast completion
        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_complete,
          session_id
        })

        :ok

      {:aquila_error, reason, ^ref} ->
        Logger.warning("Stream session error", session_id: session_id, reason: inspect(reason))
        # Handle error in persistence
        handle_stream_error(persistence, session_id, reason, state, p_opts)

        # Broadcast error
        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_error,
          session_id,
          reason
        })

        {:error, reason}
    after
      timeout ->
        # Timeout
        reason = :timeout
        Logger.warning("Stream session timeout", session_id: session_id)
        handle_stream_error(persistence, session_id, reason, state, p_opts)

        Phoenix.PubSub.broadcast(pubsub, "aquila:session:#{session_id}", {
          :aquila_stream_error,
          session_id,
          reason
        })

        {:error, reason}
    end
  end

  defp handle_chunk(nil, _session_id, _chunk, state, _opts), do: state

  defp handle_chunk(persistence_module, session_id, chunk, state, opts) do
    case persistence_module.on_chunk(session_id, chunk, state, opts) do
      {:ok, new_state} ->
        new_state

      {:error, reason} ->
        Logger.warning("Persistence chunk handling failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        state
    end
  end

  defp handle_tool_call(nil, _session_id, _tool_name, _result, state, _opts), do: state

  defp handle_tool_call(persistence_module, session_id, tool_name, result, state, opts) do
    if function_exported?(persistence_module, :on_tool_call, 5) do
      case persistence_module.on_tool_call(session_id, tool_name, result, state, opts) do
        {:ok, new_state} ->
          new_state

        {:error, reason} ->
          Logger.warning("Persistence tool call handling failed",
            session_id: session_id,
            reason: inspect(reason)
          )

          state
      end
    else
      state
    end
  end

  defp handle_complete(nil, _session_id, _text, _state, _opts), do: :ok

  defp handle_complete(persistence_module, session_id, text, state, opts) do
    case persistence_module.on_complete(session_id, text, state, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Persistence completion failed",
          session_id: session_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp handle_stream_error(nil, _session_id, _reason, _state, _opts), do: :ok

  defp handle_stream_error(persistence_module, session_id, reason, state, opts) do
    persistence_module.on_error(session_id, reason, state, opts)
  end
end
