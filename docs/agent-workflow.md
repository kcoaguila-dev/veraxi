# Agent Workflow — Lessons from T3 Code

*Written 2026-11-27. A comparison of Veraxi with [T3 Code](https://github.com/pingdotgg/t3code)
(`pingdotgg/t3code`), focused on how each project manages coding work in the AI era:
what T3 does well, what Veraxi already does, what this repo adopts from it, and what it
deliberately does not. Claims about T3 are from its repo (`AGENTS.md`, `CONTRIBUTING.md`,
`.github/pull_request_template.md`, `docs/`, `packages/`) and public reviews, checked
2026-11-26/27. Star counts and scores are snapshots, not quality measures.*

## What each project is

- **Veraxi** is an evidence-first research workbench: a Hybrid GraphRAG engine
  (Neo4j + Qdrant, MiniLM dense + BM25 sparse by default, cross-encoder reranker,
  Reciprocal Rank Fusion) exposed over MCP, with a Flutter client, a code-intelligence
  and security graph, and machine-verified per-claim citations. Veraxi *is* the agent:
  its own LangGraph loop does the retrieval and the answering.
- **T3 Code** is the inverse: it is *not* an agent. It is a local control plane — a
  Node server on the user's machine is the sole execution boundary, and web, desktop,
  and phone are remotes over one WebSocket. It drives vendor harnesses (Claude Code,
  Codex, Cursor, OpenCode, and ACP agents such as Antigravity, Grok, Kiro, Copilot)
  through each vendor's official machine interface, normalising them into one
  thread / turn / item / approval / plan / usage event model.

That difference decides what is portable. T3's product machinery mostly is not
Veraxi's problem; T3's *repo and workflow discipline* is, because both projects are
built largely by AI agents under human direction.

## What the web says about T3 Code

Two eras, and the distinction matters:

- **Early alpha (Mar 2026)** reviews were lukewarm: ~3.5/5, "alpha software, and it
  feels like alpha software", UI contrast and polish complaints, hundreds of open
  issues. It ran only Codex at first.
- **Oct–Nov 2026** the reputation flipped on workflow, not on the model: in one
  Hacker News sample 19 of 24 commenters recommended it. The durable praise is
  consistent across friendly and hostile reviews alike: one UI over every provider,
  a git worktree per thread, a checkpoint per turn, phone-as-remote approvals, and
  flat subscription cost instead of per-token metering. The most detailed favourable
  write-up (Flavio Copes, updated 2026-11-25) frames the real problem T3 solves as
  *tracking* many agents — who is waiting for approval, which diff belongs to which
  turn, how much quota is left — not running one agent.
- **The design-council story is a method, not an award.** T3's PR #24837 iterated its
  UI through multi-model screenshot scoring: two judges scored it 9.0 against Claude
  Code 8.3 and Codex 8.4–8.5; a third judge dissented at 7.9. Later retellings
  (9.5, 10/10) come from the maintainer's own runs, which also showed the scores
  move when the anchors change. Steal the loop — comparative screenshots, several
  judges, iterate to a score — not the headline number.
- **The telemetry controversy is the cautionary tale.** In Nov 2026 an audit showed
  telemetry had shipped on by default since Mar 2026 while the homepage said
  "No telemetry / Unless you opt in", that the opt-out was a buried environment
  variable, and that one version read provider auth files to build analytics
  identities (hashed, but unsalted). The fixes landed within days (v0.1.12,
  2026-11-25 removed the provider-file reads), but the trust cost was far larger
  than the engineering cost. Lesson: defaults and marketing copy are part of the
  security surface, and "we fixed it fast" does not undo "the copy said the
  opposite of the code".

## Side by side: T3 practice → Veraxi status

| T3 practice | Veraxi status |
| :--- | :--- |
| One adapter per vendor protocol, normalised to a single event model | **Already have it, for the one case that matters.** ADR-0005: external runtimes plug in behind `agent_runtime`, ACP (JSON-RPC 2.0 / NDJSON over stdio) first, with Veraxi's MCP served *into* the driven session. T3 normalises many agents; Veraxi normalises runtimes behind its own evidence engine. |
| Official machine interfaces only — never scrape CLI stdout | **Already the rule.** ADR-0005 mandates the official `agy acp` binary, allowlisted subprocess environment, zero credential handling. |
| Git worktree per thread | **Partially have it.** The Code composer carries repo / branch / worktree state (`app/lib/features/chat/views/widgets/code_chat_composer.dart`); the sandbox and local runner execute inside one worktree. Full worktree-per-thread isolation for native threads is not built. |
| Per-turn checkpoints as hidden git refs (`refs/t3/checkpoints/`) | **Not have it — candidate.** Veraxi's checkpoints are conversation state (LangGraph checkpointer, compaction + one-click restore), not per-turn git snapshots of the workspace. For driven/native coding threads, T3's mechanism is the honest way to make "revert this turn" real. Listed here so the gap is on record, not silently implied. |
| Phone / web as remote over a local execution boundary | **Different shape, deliberately.** Veraxi is hosted-first so users with fewer resources can use it from a phone browser; T3 requires the host machine to stay on. Veraxi's local runner (`runner/`, outbound WebSocket, tenant token) is the same boundary idea pointed the other way. |
| `packages/contracts` — pure schema package, no runtime logic, imported by server and every client | **Portable idea, different artefact.** A TypeScript schema package cannot be shared by a Python backend and a Flutter client. Veraxi's equivalent contracts are the OpenAPI schema and the MCP tool schemas; the discipline to copy is "wire changes land in the contract first, clients follow", which the ACP protocol types in `backend/acp/protocol.py` already follow for driven sessions. |
| `AGENTS.md` as the canonical agent file; `CLAUDE.md` is one line: `@AGENTS.md` | **Not adopted here — owner's decision.** Veraxi's `CLAUDE.md` is generated by `vx rules sync` from `.veraxi/rules.json`, a different mechanism with a different job (syncing architectural constraints into several tools' rule files). Collapsing the two into one source of truth is worth deciding explicitly; this doc records the gap instead of papering over it. |
| PR template: Problem / Change / Scope / **Verification** — "'Tests pass' alone is insufficient", screenshots for UI, and an agent-attribution line | **Adopted in this PR** (`.github/PULL_REQUEST_TEMPLATE.md`). Veraxi's old template was checkboxes only. |
| `CONTRIBUTING.md`: "Show that it works — say how you found the bug, how you checked it, and what you saw" | **Adopted in this PR** (`CONTRIBUTING.md`, Pull requests section). |
| `AGENTS.md`: "Hit every surface" checklist — a change is not done until every entry point, client, provider, and reverse state has a decision | **Adopted in this PR**, adapted to Veraxi's surfaces (`AGENTS.md`, "Hit every surface"). |
| `AGENTS.md`: "The three ways to hurt yourself" — concrete, repo-specific footguns up front | **Adopted in spirit.** Veraxi's hard rules already carry most of this (parameterised Cypher, no silent test weakening, scrubbed subprocess env in ADR-0005); the surface checklist is where new footguns get recorded. |
| One problem per PR; cleanup and second fixes go in their own PRs | **Already the stated rule** in `CONTRIBUTING.md` ("Keep PRs scoped to one concern"); restated for agents in `AGENTS.md` ("Working method"). |
| `evals/` as a top-level, named discipline (per-feature eval folders) | **Already have it** as `backend/evaluation/` (deterministic + DeepEval suites, code-accuracy fixture). Kept where the code is; no rename for symmetry's sake. |
| Nightly release train (hundreds of nightly releases) | **Not adopted.** Veraxi ships tagged releases from `main`; a solo maintainer gains nothing from a nightly train except version-skew support burden — the exact complaint reviewers raise about T3's server/client version coupling. |
| New threads default to **Full access** | **Not adopted — anti-pattern for Veraxi.** ADR-0005's posture is supervised-by-default with a scrubbed environment. T3's own reviewers flag the full-access default as its sharpest footgun. |
| Telemetry on by default, opt-out by env var | **Not adopted — anti-pattern.** See the controversy above. Veraxi error reporting (Sentry) must stay documented where users can find it, and Veraxi never reads other tools' credential or auth files to build identities. |
| Closed governance: "We are explicitly NOT INTERESTED in new feature PRs", 3-open-PR limits, bans list | **Not adopted.** It fits a project drowning in contributions (T3 reports ~1,500 open issues); Veraxi is pre-launch and wants contributors. The portable part is honesty about review capacity, which `CONTRIBUTING.md` already states by asking for an issue first on anything beyond a small fix. |
| Repo-level `skills/` for agent workflows | **Already have it** (`skills/` — landing-page, neo4j, qdrant). T3 ships one (`t3-workflows`); both repos converged on "repeatable agent procedures live in the repo, versioned with the code". |

## The workflow both repos converge on

Stripped of product differences, T3's repo discipline and the senior-dev consensus
agree on the same loop, which `AGENTS.md` now states for Veraxi:

1. **Spec first for anything non-trivial** — a short written spec or plan the human
   approves before code (T3's issues/discussions gate; Veraxi's ADRs for
   irreversible decisions, `docs/ROADMAP.md` for phase order).
2. **One problem per PR**, as a vertical slice: contract, server, client, tests,
   and docs for that one problem — nothing else riding along.
3. **Test-first inside the slice**, and the agent that writes the implementation
   does not get to weaken the tests that define it.
4. **Verification is evidence, not assertion** — commands run, output seen,
   screenshots for UI, and an explicit list of what was *not* checked.
5. **Small PRs, merged promptly**, with a conventional-commit title; the PR body
   names the problem, the change, the scope, and the verification.

## Sources

- T3 Code repo: <https://github.com/pingdotgg/t3code> — `AGENTS.md`,
  `CONTRIBUTING.md`, `.github/pull_request_template.md`, `docs/user/faq.md`,
  `packages/contracts` (checked 2026-11-26/27).
- T3 design-council PR: <https://github.com/pingdotgg/t3code/pull/24837>
- Flavio Copes, "T3 Code" deep dive (updated 2026-11-25): <https://flaviocopes.com/t3-code/>
- Hacker News reception sample: <https://hackerapproved.com/p/t3-code/>
- Telemetry audit and remediation coverage: <https://developerscodex.com/t3-code-telemetry/>,
  <https://www.binmage.com/t3-code-telemetry-default-on/>
- Early review (Mar 2026): <https://leonardmartinis.com/blog/t3-code-review/>
- Veraxi side: `docs/adr/0005-acp-external-agent-runtimes.md`, `AGENTS.md`,
  `CONTRIBUTING.md`, `backend/acp/`, `runner/README.md`.
