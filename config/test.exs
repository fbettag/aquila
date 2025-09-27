import Config

config :aquila,
  transport: Aquila.Transport.Record,
  recorder: [
    path: "test/support/cassettes",
    transport: Aquila.Transport.OpenAI
  ]

config :aquila, :openai,
  base_url: "https://api.openai.com/v1",
  api_key: "test",
  default_model: "gpt-4o-mini",
  request_timeout: 30_000
