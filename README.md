# Aeon

A lightweight AI assistant that runs locally and can interact with your system through shell commands and file operations.

## Features

- **CLI & Telegram interfaces** — Chat locally or connect via Telegram bot
- **LLM providers** — OpenAI (default), Anthropic (planned)
- **Built-in tools** — File read/write, shell command execution
- **Customizable roles** — Define assistant personality via markdown files
- **Skills system** — Extensible capabilities through skill definitions

## Quick Start

```bash
# Build
zig build

# Copy and configure environment variables
cp .env.example .env
# Edit .env and add your API keys

# Load environment and run (CLI mode)
source .env && ./zig-out/bin/aeon

# Or specify a config file
source .env && ./zig-out/bin/aeon --config=my_config.json
```

See [.env.example](.env.example) for all available environment variables.

## Configuration

Create a JSON config file (e.g., `aeon.json`):

```json
{
    "log_file_path": "~/.aeon/logs/aeon.log",
    "role_path": "~/.aeon/roles/Assistant.md",
    "messenger": "cli",
    "llm_provider": "openai",
    "llm_model": "gpt-4o-mini"
}
```

### Config Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `log_file_path` | string | none | Path to log file (supports `~` expansion) |
| `role_path` | string | none | Path to role markdown file defining assistant personality |
| `messenger` | string | `"cli"` | Interface: `"cli"` or `"telegram"` |
| `llm_provider` | string | `"openai"` | LLM backend: `"openai"` or `"anthropic"` |
| `llm_model` | string | `"gpt-4o-mini"` | Model name to use |

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes (for OpenAI) | Your OpenAI API key |
| `TELEGRAM_BOT_TOKEN` | Yes (for Telegram) | Telegram bot token from @BotFather |

## Roles

Roles define the assistant's personality and behavior. Place markdown files in `roles/`:

- `Assistant.md` — General purpose assistant
- `Developer.md` — Software development focus
- `DevOps.md` — Infrastructure and deployment
- `Writer.md` — Content creation
- `SecurityAnalyst.md` — Security analysis
- `DataScientist.md` — Data analysis and ML

Set the role in your config:

```json
{
    "role_path": "roles/Developer.md"
}
```

## Skills

Skills are markdown files in the `skills/` directory that teach the assistant specific capabilities:

- `shell_commands.md` — System command execution
- `file_operations.md` — File read/write operations
- `tool_usage.md` — General tool usage guidelines

## Built-in Tools

| Tool | Description |
|------|-------------|
| `file_read` | Read file contents |
| `file_write` | Write content to file |
| `exec` | Execute shell commands (with stdin and timeout support) |

## Project Structure

```
aeon/
├── src/
│   ├── aeon.zig          # Entry point
│   ├── agent/            # LLM clients, runtime, tools
│   ├── core/             # Config, logging, CLI
│   ├── messengers/       # CLI & Telegram interfaces
│   └── utils/            # HTTP, environment, utilities
├── roles/                # Role definition files
├── skills/               # Skill definition files
└── docs/                 # Architecture documentation
```

## Requirements

- Zig 0.15+
- OpenAI API key (or Anthropic when supported)

## License

MIT
