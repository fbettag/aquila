Application.put_env(:aquila, Aquila.TestEndpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "1234567890"],
  url: [host: "localhost"],
  pubsub_server: Aquila.TestPubSub
)

ExUnit.start()
