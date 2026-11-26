# Veraxi on GitHub Codespaces — host & user-recreation testing

Run the real Veraxi stack in a codespace and use it from your phone the way a
hosted user would — while keeping Docker, persistence, and your own git
identity, which a Colab runtime cannot offer.

## Files

| File | Purpose |
|---|---|
| `devcontainer.json` | 4 CPU / 16 GB host requirement, docker-in-docker, GitHub CLI, Python 3.12, port forwarding (8000 API, 8080 Web, 7474 Neo4j, 6333 Qdrant) |
| `post-create.sh` | Waits for Docker, creates `backend/.env` (test values), pre-pulls neo4j/qdrant/redis images |
| `host-up.sh` | Derives this session's forwarded URLs, patches `CORS_ORIGINS`, sets the web build's `API_URL`, builds + starts the stack, prints the phone URLs |
| `host-down.sh` | Stops the stack; `--wipe` also deletes data volumes (true cold start) |
| `../docker-compose.codespaces.yml` | Override that publishes the Flutter `web` container on 8080 (base compose only exposes it through Caddy, whose site block is bound to `api.veraxi.me` and won't answer `*.app.github.dev` hosts) |

## Use

1. Repo → **Code → Codespaces → Create codespace on main** (4-core is the
   largest size selectable without billing setup).
2. Add your LLM key to `backend/.env` (`LLM_API_KEY`, optionally
   `LLM_BASE_URL` / `LLM_MODEL_NAME`) — created for you by post-create.
3. Run `.devcontainer/host-up.sh`. First build takes several minutes.
4. Open the printed web URL on your phone (signed in to GitHub — forwarded
   ports are private by default) and use Veraxi like a user: connect/index a
   repo, chat, check citations.
5. `.devcontainer/host-down.sh` when done; stop the codespace itself to stop
   the quota meter (30 min idle auto-stop is on by default).

## Test-instance choices (deliberate)

- `AUTH_ENABLED=false` + `WORKER_MODE=inline` + `INGESTION_PROFILE=lite` —
  the documented single-user configuration from `backend/.env.example`.
- SearXNG/Tor (profile `search`) are not started, so CRAG web search reports
  unavailable; everything else is the production topology.
- Neo4j password aligned to the compose default
  (`changeme_local_password`). Note: `backend/.env.example` ships a different
  `NEO4J_PASSWORD` (`neo4j_password_123`); under compose the `environment:`
  block overrides `env_file`, so the example value only bites non-compose
  runs — worth fixing separately.

## Quota math

GitHub Free includes 120 core-hours + 15 GB storage monthly (Pro: 180/20 GB).
This 4-core codespace burns 4 core-hours per active hour → ~30 h/month free.
The 32 GB disk is the tightest resource (Flutter build image is large);
delete stale codespaces, and step up to 8-core (32 GB RAM, larger disk,
~15 free h/month) for big indexing runs.

## Codespaces vs Colab (same job, different tool)

- **Codespaces**: Docker as designed, persistent volumes, private stable
  URLs, your git identity (can push workflow files). No GPU, 16 GB RAM.
- **Colab (AI Pro, CPU High-RAM / GPU)**: 51 GB RAM and GPUs for eval and
  reranker work, near-free CPU burn (~0.26 units/h of 200/month), but
  ephemeral, Docker-less, public rotating tunnel URLs. Best kept for GPU
  jobs and deliberate cold-start first-run recreations (see the Colab boot
  notebook).
