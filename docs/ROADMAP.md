\# Roadmap



This project follows a \*\*walking skeleton\*\* approach — build the thinnest possible

end-to-end slice first, prove the riskiest connections work, then add breadth and polish.

Phases are ordered by risk, not by file-tree position or feature importance.



\## Phase 0 — Scaffolding

\- \[x] Repo init, `.gitignore`, `LICENSE`, `docker-compose.yml`

\- \[x] `.env.example` files, `config.py` reading env vars

\- \[x] Folder structure (backend + Flutter app)



\## Phase 1 — Prove the riskiest link: ingestion + dual-write linking

\- \[ ] Chunk one hardcoded document, embed it, write to Qdrant

\- \[ ] Extract entities/relations from the same document, write to Neo4j

\- \[ ] Confirm Neo4j nodes and Qdrant points are correctly linked by ID, both directions

\- \[ ] `test\_ingestion\_linking.py` — asserts every written node/point pair is actually linked



This is the highest-risk unknown in the whole project. Everything else depends on this

working reliably — prove it first, with the ugliest possible code, before building anything

around it.



\## Phase 2 — Retrieval and merge\_rank

\- \[ ] `merge\_rank.py` — combine and rank graph + vector results

\- \[ ] `test\_merge\_rank.py` — fake inputs, known-correct expected output

\- \[ ] Test against the tiny dataset from Phase 1, where the "correct" answer is known



\## Phase 3 — LLM chat loop + MCP tools

\- \[ ] `mcp\_server/tools/query\_graph.py`, `search\_vectors.py`

\- \[ ] `llm\_loop.py` — LLM decides when to call tools, returns an answer

\- \[ ] Test via command line / script — no UI needed yet

\- \[ ] `test\_mcp\_tools.py` — mocked DB clients, no real Neo4j/Qdrant required



\## Phase 4 — Flutter chat screen

\- \[ ] `features/chat` — chat\_repository, chat\_view\_model, chat\_screen

\- \[ ] Wired to the now-working backend from Phase 3

\- \[ ] `chat\_view\_model\_test.dart`



\## Phase 5 — Control panel

\- \[ ] `features/control\_panel` — view graph/vector contents, trigger ingestion manually

\- \[ ] Lower priority than chat — admin convenience, not core value

\- \[ ] Good candidate for `good first issue` labels once open to contributors



\## Phase 6 — Hardening

\- \[ ] CI running lint (`ruff`, `dart analyze`) + tests on every PR

\- \[ ] `pip-audit` / `npm audit` dependency check

\- \[ ] README polish — setup instructions, screenshot/gif of chat working

\- \[ ] `CONTRIBUTING.md` filled in with real dev-environment setup steps



\---



\*\*Currently here:\*\* starting Phase 1.

