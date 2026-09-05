# Complete application: support assistant

The [support-assistant application](https://github.com/fbettag/aquila/tree/main/examples/support_assistant)
contains a runnable Mix project, policy tool, streaming CLI, deterministic model
substitute and tests. Start with the offline mode; no API key is required.

```sh
cd examples/support_assistant
mix deps.get
mix test
mix run -e 'SupportAssistant.CLI.main([])'
```

The application passes the question to Aquila, executes an allowlisted policy
lookup when the model requests it, then consumes chunk, done and error messages.
The lookup never writes account state. Unknown policies escalate to a human.
Use the README's explicit live-mode instructions to use an actual model.

This is an integration example, not a benchmark or a production security audit.
See [cassette testing](cassettes-and-testing.md) for provider recording and replay.
