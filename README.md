# Deploy and Host

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.com/deploy/openbot-lite)

**OpenBot Lite** — [OpenBot](https://github.com/CopilotKit/OpenBot) by CopilotKit — is an open-source AI-coworker runtime that speaks the [AG-UI protocol](https://github.com/agent-protocol): persistent coworker bots with a policy gateway, a credential vault, and an append-only audit log — with any agent harness (built-in bots, or external LangGraph / Mastra / CrewAI agents over AG-UI).

This Lite template ships the whole runtime in **one container** (the official `ghcr.io/copilotkit/openbot:v0.0.15` image): AG-UI server + web UI + up to 3 built-in bots + an embedded Chromium "computer" for browser-using bots + **embedded Postgres 16 (pgvector)** for the audit trail and policy store — no companion database service required, and every bot's state survives redeploys on a persistent volume.

- Web app: **/agents**, **/audit**, **/credentials**, **/settings**, SSO provider management (**/sso/providers**)
- Single-user mode by default (every visitor is the admin, no passwords, no registration) — flip to SSO (Google / Microsoft Entra / Okta) when the domain is shared
- Credential vault encrypted with **KEY_ENCRYPTION_KEY**, auto-generated once and persisted on the volume — redeploys never lock you out of stored secrets
- Durable threads & bot memory via **CopilotKit Intelligence** (managed `api.intelligence.copilotkit.ai` — the Pro plan)
- Point `OPENAI_API_KEY` / `OPENAI_BASE_URL` at OpenAI or any OpenAI-compatible gateway (vLLM, Ollama, LiteLLM)
- Optional external harness: `MANAGED_AGENT_AG_UI_URL` + `MANAGED_AGENT_TOKEN` for LangGraph / Mastra / CrewAI agents

## Why Deploy

OpenBot is one of the clearest open-source implementations of the AG-UI protocol: it gives agents a real "computer" — browser, file workspace, credential vault, audit trail — with human takeover and per-agent policy gates. Shipping it as a single-container Railway template means:

- **One click** — no companion Postgres to configure, no Helm chart, no S6 container orchestration (the base image handles it internally)
- **Persistence** — one Railway volume covers the Postgres cluster, the credential vault encryption key, bot workspaces, and Chromium login profiles; a redeploy never loses state
- **SSO-ready** — the entrypoint shim detects which sign-in provider you configure and sets `TRUSTED_ORIGINS` + `OPENBOT_SINGLE_USER` so the app's own boot guards are always satisfied
- **Any LLM** — OpenAI, vLLM, Ollama, LiteLLM, or any OpenAI-compatible endpoint via `OPENAI_BASE_URL`
- **External harness support** — bring your own LangGraph / Mastra / CrewAI agent over AG-UI via `MANAGED_AGENT_AG_UI_URL`

## Required inputs

Two things are **mandatory** — the server refuses to start without them, by design:

| Variable | Where to get it |
|---|---|
| `INTELLIGENCE_API_KEY` | https://intelligence.copilotkit.ai → your project → **API Keys** (a `cpk-...` runtime key; CopilotKit Pro plan) |
| `OPENAI_API_KEY` | Any OpenAI key, or a key for an OpenAI-compatible endpoint via `OPENAI_BASE_URL` |

`INTELLIGENCE_API_URL` and `INTELLIGENCE_GATEWAY_WS_URL` are pre-filled with the managed-service URLs and should stay that way.

## Source Repository

[https://github.com/CopilotKit/OpenBot](https://github.com/CopilotKit/OpenBot) · image: `ghcr.io/copilotkit/openbot:v0.0.15` · template repo: [https://github.com/mc9max/openbot-lite](https://github.com/mc9max/openbot-lite)

## System Requirements

- **RAM:** 2 GB+ recommended (embedded Postgres + bot runtime + Chromium)
- **Disk:** 1 Railway volume (5 GB minimum) — Postgres cluster, credential vault, audit trail, bot workspaces + Chromium profiles all live on it
- **Network:** HTTPS domain; outbound to your LLM endpoint and to `*.intelligence.copilotkit.ai`
- **Accounts:** a CopilotKit Intelligence project (Pro) + an OpenAI (or compatible) API key

## About Hosting

Single service, Dockerfile build from the pinned upstream image, plus a small entrypoint shim that does the things a fresh Railway deployment needs that the base image won't do by itself:

1. **Stable KEY_ENCRYPTION_KEY** — auto-generated once, persisted on the volume, re-exported every boot. A key rotated out from under the vault would corrupt stored secrets.
2. **Sign-in gate** — detects whether an SSO provider is configured and puts the app into the matching posture, anchoring `BETTER_AUTH_URL`/`TRUSTED_ORIGINS` to the public domain so the app's "no public origin while single-user" and "no sign-in configured" boot guards are always satisfied.
3. **Embedded Postgres on** — the base image ships `EMBEDDED_POSTGRES=off` (multi-container shape); we set it `on` so the whole stack runs in one container.
4. **Bot state on the one volume** — the base image keeps `/workspace` (bot dirs) and `/profiles` (Chromium logins) in ephemeral baked dirs. The shim re-points both onto the persistent volume via symlinks so every bot's files and browser logins survive a redeploy.

One Railway volume (Railway allows exactly **one volume per service**), mounted at the parent directory exactly as the image's own `postgres-init.sh` requires — a volume mounted directly on the data dir arrives with `lost+found` and `initdb` refuses it. Everything durable lives under it:

| Path on the volume | Purpose |
|---|---|
| `/var/lib/postgresql/data` | Postgres cluster — bots, credential vault, policy store, append-only audit trail |
| `/var/lib/postgresql/.openbot.key` | The persisted `KEY_ENCRYPTION_KEY` |
| `/var/lib/postgresql/workspace` | Bot working directories (symlinked as `/workspace`) |
| `/var/lib/postgresql/profiles` | Per-bot Chromium profile state — logins, cookies (symlinked as `/profiles`) |

## Dependencies for OpenBot Lite

### Deployment Dependencies

All in-container. The only external services the app talks to:

1. **CopilotKit Intelligence** (durable threads/memory) — `INTELLIGENCE_API_URL`, `INTELLIGENCE_GATEWAY_WS_URL`, `INTELLIGENCE_API_KEY` *(required)*
2. **Your LLM** — `OPENAI_API_KEY` (+ optional `OPENAI_BASE_URL`) *(required)*

Optional: an external AG-UI harness (`MANAGED_AGENT_AG_UI_URL` + `MANAGED_AGENT_TOKEN`, and `AGENT_TOOL_TOKEN` for tool-callbacks back through this server).

## Ports

- `3001` — web UI + AG-UI API (health at `/health`; both `PORT` and `SERVER_PORT` are wired to match)

## Common Use Cases

- A private "AI coworker" desk: persistent bot state, auditable credential vault, single admin
- An AG-UI endpoint that CopilotKit front-ends (or other agents) can call directly
- A policy-gated sandbox for bots that hold credentials (GitHub tokens, API keys) with an append-only audit trail and a one-line retention knob (`AUDIT_RETENTION_DAYS`)

## License

OpenBot is licensed under the MIT License.
