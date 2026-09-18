# TypeSafe Jev

`Aquila.TypeSafe` connects Elixir applications to TypeSafe System One models.
Jev evaluates shared application state against independent typed questions. It
returns decisions, probability distributions, confidence, and token usage. It
does not generate prose.

Use Jev where code needs a bounded semantic decision such as classification,
relevance scoring, routing, ranking, policy checks, or whether evidence supports
a claim. Keep arithmetic, date logic, exact matching, side effects, and final
thresholds in deterministic application code.

## Configuration

Configure the API key at runtime. Aquila also resolves `TYPESAFE_API_KEY` and
then `TYPESAFE_API_KEY_FILE` automatically when `:api_key` is unset.

```elixir
config :aquila, :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"},
  base_url: "https://api.typesafe.ai/v1",
  default_model: "jev-latest",
  request_timeout: 60_000
```

For file-based secrets use `api_key: {:file, "/run/secrets/typesafe-api-key"}`.
Options passed to `evaluate/3` and `list_models/1` override application config.

## Evaluate typed questions

All questions in a request see the same state and are evaluated independently.
Question IDs can be atoms or strings and are returned as string keys.

```elixir
alias Aquila.TypeSafe
alias Aquila.TypeSafe.Answer.{Choice, Noul, Score}
alias Aquila.TypeSafe.Question

state = %{
  theme: "Healthy human longevity",
  claim: "Rapamycin extends healthy lifespan in humans.",
  passage: "A mouse study reported a longer median lifespan."
}

questions = %{
  claim_type: Question.choice("Classify the claim.", %{
    "effect" => "An intervention changes an outcome",
    "mechanism" => "A causal or biological pathway",
    "descriptive" => "A factual event or status"
  }),
  relevance: Question.score("How relevant is the passage to the theme?", [
    "Unrelated",
    "Adjacent",
    "Directly useful",
    "Core evidence"
  ]),
  supported:
    Question.noul("Does the passage directly support the claim as written?", %{
      true => "Direct support",
      false => "Insufficient or contradictory support"
    })
}

{:ok, response} = TypeSafe.evaluate(state, questions)

%Choice{choice: "effect"} = response.answers["claim_type"]
%Score{score: score} = response.answers["relevance"]
%Noul{probability: probability} = response.answers["supported"]
```

`%Aquila.TypeSafe.Response{}` contains the concrete model version, typed
answers, provider token usage, and the raw response. A `score` can be fractional
because it is the probability-weighted position on the ordered rubric. A
`noul` value is the probability of the proposition being true.

Use `Aquila.TypeSafe.list_models/1` to discover the aliases and releases visible
to the account:

```elixir
{:ok, models} = Aquila.TypeSafe.list_models()
```

## Thresholds and failure behavior

The adapter validates state, question schemas, answer IDs, response shapes, and
probability bounds. Provider and HTTP failures are returned as `{:error,
reason}`. Aquila does not silently retry judgments because callers may have
latency, quota, or side-effect constraints.

Choose thresholds from representative application data and keep ambiguous cases
reviewable. For high-impact decisions, treat Jev probabilities as evidence,
not authorization.

## Recorder-backed tests

The normal Aquila recorder supports TypeSafe POST and model-list GET requests.
It records decoded responses, verifies canonical request bodies on replay, and
redacts authorization headers.

```elixir
use Aquila.Cassette

aquila_cassette "routing/article" do
  assert {:ok, result} =
           Aquila.TypeSafe.evaluate(state, %{
             route: Question.choice("Choose a route.", routes)
           })

  assert result.answers["route"].choice in Map.keys(routes)
end
```

Record a missing cassette once with a TypeSafe credential. Subsequent test runs
replay without network access or credentials and fail when the request changes.
Telemetry is emitted at `[:aquila, :typesafe, :request, :start | :stop |
:exception]`.
