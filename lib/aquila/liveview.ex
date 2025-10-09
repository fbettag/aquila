defmodule Aquila.LiveView do
  @moduledoc """
  Macro for integrating Aquila streaming into Phoenix LiveViews.

  This macro provides a convenient way to add streaming event handlers to your
  LiveView modules. It automatically implements `handle_info/2` callbacks for
  Aquila streaming events and optionally forwards them to a LiveComponent.

  ## Usage

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view

        use Aquila.LiveView,
          supervisor: MyApp.TaskSupervisor,
          pubsub: MyApp.PubSub,
          persistence: MyApp.ChatPersistence,
          timeout: 120_000,
          forward_to_component: {MyAppWeb.ChatComponent, :chat_id}

        # Your LiveView code...
      end

  ## Options

  - `:supervisor` - Required. Task.Supervisor module for async tasks
  - `:pubsub` - Required. PubSub module for broadcasting events
  - `:persistence` - Optional. Persistence module implementing `Aquila.Persistence`
  - `:timeout` - Optional. Timeout for streaming requests (default: 120_000ms)
  - `:forward_to_component` - Optional. Tuple of `{ComponentModule, assign_key}` to
    forward events to a specific LiveComponent instance

  ## Event Forwarding

  When `:forward_to_component` is specified, streaming events are forwarded to
  the specified component using `Phoenix.LiveView.send_update/3`. The component
  must have an `id` assign that matches the value in `socket.assigns[assign_key]`.

  ## Implemented Handlers

  The macro implements these `handle_info/2` callbacks:

  - `{:aquila_stream_delta, session_id, content}` - Streaming text chunk
  - `{:aquila_stream_tool_call, session_id, tool, result}` - Tool execution
  - `{:aquila_stream_usage, session_id, usage}` - Token usage
  - `{:aquila_stream_complete, session_id}` - Streaming complete
  - `{:aquila_stream_error, session_id, reason}` - Streaming error

  ## Helper Functions

  The macro also provides:

  - `subscribe_aquila_stream/2` - Subscribe to a specific session's events
  - `aquila_config/0` - Access the configuration options
  """

  @default_timeout 120_000

  defmacro __using__(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    pubsub = Keyword.fetch!(opts, :pubsub)
    persistence = Keyword.get(opts, :persistence)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    forward_to_component = Keyword.get(opts, :forward_to_component)

    quote do
      @aquila_supervisor unquote(supervisor)
      @aquila_pubsub unquote(pubsub)
      @aquila_persistence unquote(persistence)
      @aquila_timeout unquote(timeout)
      @aquila_forward_to unquote(forward_to_component)

      # Provide helper to subscribe to Aquila streams
      def subscribe_aquila_stream(socket, session_id) do
        Phoenix.PubSub.subscribe(@aquila_pubsub, "aquila:session:#{session_id}")
        socket
      end

      # Provide access to config
      def aquila_config do
        %{
          supervisor: @aquila_supervisor,
          pubsub: @aquila_pubsub,
          persistence: @aquila_persistence,
          timeout: @aquila_timeout,
          forward_to_component: @aquila_forward_to
        }
      end

      # Handle streaming delta events
      def handle_info({:aquila_stream_delta, session_id, content}, socket) do
        unquote(handle_forward_event(:streaming_delta, quote(do: content)))
      end

      # Handle tool call start events - ignore for now
      def handle_info({:aquila_stream_tool_call, session_id, :start, _metadata}, socket) do
        {:noreply, socket}
      end

      # Handle tool call end events - extract name and output
      def handle_info({:aquila_stream_tool_call, session_id, :end, metadata}, socket) do
        tool_name = Map.get(metadata, :name) || Map.get(metadata, "name")
        output = Map.get(metadata, :output) || Map.get(metadata, "output")
        unquote(handle_forward_event(:streaming_tool_result, quote(do: {tool_name, output})))
      end

      # Legacy format for simple tool calls
      def handle_info({:aquila_stream_tool_call, session_id, tool, result}, socket) do
        unquote(handle_forward_event(:streaming_tool_result, quote(do: {tool, result})))
      end

      # Handle usage events
      def handle_info({:aquila_stream_usage, session_id, usage}, socket) do
        unquote(handle_forward_event(:streaming_usage, quote(do: usage)))
      end

      # Handle completion events
      def handle_info({:aquila_stream_complete, session_id}, socket) do
        unquote(handle_forward_event(:streaming_complete, quote(do: true)))
      end

      # Handle error events
      def handle_info({:aquila_stream_error, session_id, reason}, socket) do
        unquote(handle_forward_event(:streaming_error, quote(do: reason)))
      end
    end
  end

  defp handle_forward_event(event_type, value_ast) do
    quote do
      case @aquila_forward_to do
        nil ->
          # No forwarding configured, just return socket
          {:noreply, socket}

        {component_module, assign_key} ->
          # Forward to component
          component_id = Map.get(socket.assigns, assign_key)

          if component_id do
            Phoenix.LiveView.send_update(
              component_module,
              [{:id, component_id}, {unquote(event_type), unquote(value_ast)}]
            )
          end

          {:noreply, socket}
      end
    end
  end
end
