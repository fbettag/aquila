# Support assistant: a complete Aquila application

Created by [Franz Bettag](https://bett.ag/en/franz-bettag).

This runnable Mix application connects a bounded support-policy tool, Aquila's
orchestration loop, streaming PID sink and a CLI that handles completion, error
and timeout. It cannot change accounts or issue refunds.

## Run without credentials or network calls

From this directory (use the Aquila devcontainer for Elixir work):

```sh
mix deps.get
mix test
mix run -e 'SupportAssistant.CLI.main([])'
```

The offline transport simulates a model tool call and final answer. It is a
fixture, not an actual language model or a quality benchmark. The real Aquila
engine dispatches the policy tool and sends streaming events.

## Run with a real model

Set `OPENAI_API_KEY` and `OPENAI_MODEL` in your environment, then explicitly opt in:

```sh
mix run -e 'SupportAssistant.CLI.main(["--live", "What is the refund policy?"])'
```

Live requests consume API quota. The example uses Aquila from the surrounding
checkout. In a separate application use the source release documented in the
root README. Do not paste credentials into files or prompts.

## Architecture and limits

Question → Aquila → model tool request → allowlisted local policy lookup →
model response → PID sink → CLI. Unknown topics return an error for human
escalation. The model receives no filesystem, shell or account-write tool.
Retrieved text remains untrusted data; instructions are not an authorization
boundary. Tool capabilities and application-owned access checks are the boundary.

Tests run the tool loop offline, unknown-topic failure and transport failure.
They establish application behavior, not accuracy, latency or production SLA.
