git config --global --add safe.directory /workspace

npm install --prefix assets || (echo "Failed to install npm dependencies." && exit 1)

mix deps.get || (echo "Failed to get mix dependencies." && exit 1)
mix git_hooks.install || (echo "Failed to install git hooks." && exit 1)

npm install -g @openai/codex @anthropic-ai/claude-code @google/gemini-cli
