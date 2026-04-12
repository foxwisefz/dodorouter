# DodoRouter 🦤

DodoRouter is a fast, reliable, and secure LLM proxy and routing engine built with Elixir and Phoenix. It provides an OpenAI-compatible API endpoint that intelligently routes your AI requests to different model providers (like Moonshot and Zai) based on your custom routing rules, while keeping your provider API keys secure.

[![DodoRouter Demo](https://img.youtube.com/vi/2MUJZwMC5PA/0.jpg)](https://youtu.be/2MUJZwMC5PA)

*Click the image above to watch the demo video!*

## Features

- **OpenAI-Compatible Endpoint**: Drop-in replacement for any app already using the OpenAI SDK.
- **Smart Routing**: Configure fallback chains so if one provider goes down, your request automatically falls back to another.
- **Provider Key Management**: Securely store and manage your API keys for various LLM providers (supports Infisical integration).
- **Live Logs & Analytics**: Real-time request logging, latency tracking, and token usage analytics built with Phoenix LiveView.
- **Blazing Fast**: Built on Elixir/OTP for high concurrency and low latency proxying.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (1.14+)
- [Erlang/OTP](https://www.erlang.org/downloads) (25+)
- [PostgreSQL](https://www.postgresql.org/download/) (12+)

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/foxwise-ai/dodorouter.git
cd dodorouter
```

### 2. Install dependencies

```bash
mix deps.get
```

### 3. Configure the database

Ensure PostgreSQL is running, then setup your database:

```bash
mix ecto.setup
```

*Note: By default, the app expects a local PostgreSQL instance with user `postgres` and password `postgres`. You can change this in `config/dev.exs`.*

### 4. Start the Phoenix server

```bash
mix phx.server
```

You can now visit [`localhost:4000`](http://localhost:4000) from your browser. Create an account, set up your first router, and you'll receive a DodoRouter API key.

## Usage

Once you have your DodoRouter API key and have configured your routing steps, you can use it exactly like the OpenAI API:

### cURL

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-dodo-YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default", 
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:4000/v1",
    api_key="sk-dodo-YOUR_API_KEY"
)

response = client.chat.completions.create(
    model="default", # The specific model will be chosen by your routing rules
    messages=[{"role": "user", "content": "Hello!"}]
)

print(response.choices[0].message.content)
```

## Deployment

Ready to run in production? DodoRouter includes a `Dockerfile` and `infra/docker-compose.yml` for easy deployment.

### Environment Variables

For production, you'll need to set the following environment variables:

- `DATABASE_URL`: Ecto database URL (e.g., `ecto://user:pass@host/dodo_router_prod`)
- `SECRET_KEY_BASE`: Generate one with `mix phx.gen.secret`
- `PHX_HOST`: Your domain name
- `PORT`: (Optional) Defaults to 4000
- `RESEND_API_KEY`: (Optional) For transactional emails
- `INFISICAL_TOKEN` / `INFISICAL_PROJECT_ID`: (Optional) If you are using Infisical for external secret storage.

For detailed deployment instructions, [check the official Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[O’Saasy License](https://osaasy.dev/)

Copyright © 2026, Foxwise AI.
