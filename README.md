---
title: HermesFace
emoji: 🔱
colorFrom: purple
colorTo: blue
sdk: docker
pinned: false
license: mit
short_description:Hermes
app_port: 7860
tags:
  - huggingface
  - hermes-agent
  - nousresearch
  - chatbot
  - llm
  - ai-assistant
  - whatsapp
  - telegram
  - text-generation
  - openai-api
  - openai-compatible
  - huggingface-spaces
  - docker
  - deployment
  - persistent-storage
  - agents
  - multi-channel
  - free-tier
  - self-hosted
  - messaging-bot
  - self-improving
---

<div align="center">
  <img src="HermesFace.png" alt="HermesFace" width="720"/>
  <br/><br/>
  <strong>Your always-on, self-improving AI agent on Hugging Face Spaces</strong>
  <br/>
  <sub>Hermes Agent · 9Router · Storage Bucket persistence · Telegram · Discord · Slack · WhatsApp · 16+ channels</sub>
  <br/><br/>

  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  [![Hugging Face](https://img.shields.io/badge/HF%20Space-yellow)](https://huggingface.co/spaces/tao-shen/HermesFace)
  [![Hermes Agent](https://img.shields.io/badge/Hermes_Agent-Powered-blueviolet)](https://github.com/NousResearch/hermes-agent)
  [![9Router](https://img.shields.io/badge/9Router-LLM%20API-green)](https://github.com/decolua/9router)
  [![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
</div>

---

## What You Get

HermesFace deploys the latest Hermes Agent source build on Hugging Face Spaces and routes LLM traffic through a local 9Router instance.

| | |
|---|---|
| **Persistent state** | Hugging Face Storage Bucket mounted at `/opt/data` keeps conversations, memories, skills, config, and 9Router state across restarts |
| **9Router LLM API** | Hermes talks to `http://localhost:20128/v1`, so the Space uses 9Router as its OpenAI-compatible provider |
| **Setup mode** | Temporarily expose the 9Router dashboard on port `7860` to configure providers, combos, and keys |
| **Agent mode** | Run Hermes dashboard on port `7860` while 9Router stays internal on port `20128` |
| **Self-improving agent** | Hermes Agent keeps its generated skills, memories, sessions, plans, and workspace under `/opt/data` |
| **Messaging channels** | Telegram, Discord, Slack, WhatsApp, Signal, WeChat, and more through Hermes gateway support |

## Quick Start

### 1. Duplicate or Create the Space

Use Docker SDK and keep `app_port: 7860`. The Space must have a Storage Bucket mounted at `/opt/data`.

### 2. Attach Storage Bucket

In the Space settings, add a Storage Bucket and mount it at:

```text
/opt/data
```

This is the only persistence layer HermesFace uses by default.

### 3. Configure 9Router

Set these Repository Secrets:

| Secret | Value |
|---|---|
| `HERMESFACE_MODE` | `ninerouter-setup` |
| `NINEROUTER_PASSWORD` | A strong password for the setup dashboard |
| `NINEROUTER_JWT_SECRET` | A long random string |

Restart the Space and open the Space URL. It will show the 9Router dashboard on port `7860`.

Use 9Router to configure your provider, Kiro/OpenCode connection, models, combos, and API keys. 9Router stores its state in:

```text
/opt/data/9router-data/db/data.sqlite
```

### 4. Start Hermes Agent

After 9Router is configured, change the Repository Secret:

```text
HERMESFACE_MODE=agent
```

Restart the Space. HermesFace will:

1. Start 9Router internally on `http://localhost:20128`.
2. Write Hermes `/opt/data/config.yaml` with:

```yaml
model:
  provider: custom
  default: kr/claude-sonnet-4.5
  base_url: http://localhost:20128/v1
  api_key: sk-local
```

3. Start the Hermes dashboard on port `7860`.
4. Start the Hermes gateway for messaging integrations.

If you want 9Router API-key enforcement in agent mode, generate a 9Router key during setup and set:

```text
NINEROUTER_API_KEY=<generated-9router-key>
```

If `NINEROUTER_API_KEY` is left as `sk-local`, the internal 9Router endpoint starts with local-only access and no API-key requirement.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `HERMESFACE_MODE` | `agent` | `agent` starts Hermes + internal 9Router; `ninerouter-setup` exposes only 9Router on `7860` |
| `NINEROUTER_PASSWORD` | empty | Password for 9Router setup mode |
| `NINEROUTER_JWT_SECRET` | `hermesface-change-me` | Session signing secret for 9Router |
| `NINEROUTER_DEFAULT_MODEL` | `kr/claude-sonnet-4.5` | Hermes default model name routed through 9Router |
| `NINEROUTER_API_KEY` | `sk-local` | API key Hermes sends to 9Router; `sk-local` disables internal API-key enforcement |
| `AGENT_NAME` | `HermesFace` | Agent display name |
| `TZ` | `UTC` | Timezone for logs and scheduled tasks |

HermesFace still passes the full environment through to Hermes Agent, so messaging tokens and other Hermes-supported variables work as Repository Secrets.

## Persistent State Layout

The Storage Bucket mounted at `/opt/data` contains all durable state:

| Path | Purpose |
|---|---|
| `/opt/data/9router-data/db/data.sqlite` | 9Router provider, combo, account, and key state |
| `/opt/data/config.yaml` | Hermes Agent config, including local 9Router provider settings |
| `/opt/data/SOUL.md` | Hermes Agent identity/persona file |
| `/opt/data/sessions` | Hermes conversation/session state |
| `/opt/data/memories` | Hermes long-term memory data |
| `/opt/data/skills` | Skills created or synced by Hermes |
| `/opt/data/plans` | In-flight Hermes plans |
| `/opt/data/workspace` | Files created by Hermes tool use |
| `/opt/data/logs` | Runner, dashboard, gateway, and runtime logs |

## Local Docker

```bash
docker build -t hermesface .
docker volume create hermesface-data

# 1. Configure 9Router
docker run --rm -p 7860:7860 \
  -v hermesface-data:/opt/data \
  -e HERMESFACE_MODE=ninerouter-setup \
  -e NINEROUTER_PASSWORD=change-me \
  -e NINEROUTER_JWT_SECRET=change-this-secret \
  hermesface

# 2. Run Hermes Agent with the same volume
docker run --rm -p 7860:7860 \
  -v hermesface-data:/opt/data \
  -e HERMESFACE_MODE=agent \
  hermesface
```

## Security Notes

- Keep `HERMESFACE_MODE=ninerouter-setup` enabled only while configuring 9Router.
- Set `NINEROUTER_PASSWORD` and `NINEROUTER_JWT_SECRET` before exposing setup mode publicly.
- In `agent` mode, 9Router listens inside the container on `20128`; Hugging Face exposes only port `7860`.
- Repository Secrets stay server-side. Do not put provider keys in files committed to the repo.
- `dns-resolve.py` keeps the existing DNS-over-HTTPS fallback for messaging APIs that are hard to resolve from HF Spaces.

## Acknowledgments

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.
- [9Router](https://github.com/decolua/9router) by decolua.
- [Hugging Face Spaces](https://huggingface.co/spaces) and Storage Buckets.

## License

MIT
