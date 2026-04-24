# swe-team

> Type a requirement. Get a PR.

[![Version](https://img.shields.io/badge/version-0.4.0-blue)](#) [![Claude Code](https://img.shields.io/badge/Claude%20Code-native-blueviolet)](#) [![License](https://img.shields.io/badge/license-MIT-green)](#)

---

## How it compares

| | **swe-team** | [addyosmani/agent-skills][1] | [garrytan/gstack][2] | aider | OpenHands |
|---|:---:|:---:|:---:|:---:|:---:|
| Multi-agent pipeline with phase gates | ✅ | ❌ | ❌ | ❌ | ⚠️ |
| Adversarial spec + plan review before coding | ✅ | ❌ | ❌ | ❌ | ❌ |
| Reads team wiki (Notion / Confluence / local vault) | ✅ | ❌ | ❌ | ❌ | ❌ |
| Writes lessons back — compounds across runs | ✅ | ❌ | ⚠️ `/retro` | ❌ | ❌ |
| CVE dep audit + OWASP + breaking-change gate | ✅ | ❌ | ⚠️ `/cso` | ❌ | ❌ |
| Mechanical evidence required — no "looks good" | ✅ | ❌ | ❌ | ❌ | ❌ |
| Opens PR automatically | ✅ | ❌ | ❌ | ❌ | ✅ |
| No external runtime — pure Claude Code native | ✅ | ✅ | ✅ | ✅ | ❌ |

[1]: https://github.com/addyosmani/agent-skills
[2]: https://github.com/garrytan/gstack

---

## How it works

```
  /swe-team "Add booking form"
            │
            ▼
  ┌────────────────────┐
  │  KNOWLEDGE SEARCH  ├──► vault · Notion · Confluence · Linear
  └─────────┬──────────┘
            │ context injected into brief
            ▼
  ┌────────────────────┐
  │  CLARIFY           │  resolves ambiguity before any spec
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  DEFINE            │  requirement → acceptance criteria
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  ADV-SPEC  ⚔       │  challenges spec — blocks on critical gaps
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  PLAN              │  ≤15 tasks · ≤500 LOC · ≤10 files/task
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  CHAL-PLAN  ⚔      │  reviews plan risks before BUILD
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  BUILD  (loop)     ├──► swe-coder: 1 task → 1 commit
  └─────────┬──────────┘
            │
            ▼
  ┌──────────────────────────────────────────┐
  │  VERIFY                                  │
  │                                          │
  │  mech   tests · lint · typecheck         │
  │         dep audit · CVE scan             │
  │                │                         │
  │                ▼ pass                    │
  │  sem    acceptance · scope · OWASP       │
  │         breaking-change detection        │
  │                                          │
  └─────────┬────────────────────────────────┘
            │ all pass    ↑ fail: retry → re-plan → abort
            ▼
  ┌────────────────────┐
  │  SHIP              │  gh pr create → base branch
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  RETRO             ├──► lessons written back to vault
  └────────────────────┘

  You review the PR.
```

---

## Quickstart

```bash
# 1. Install into your project
git clone https://github.com/quybquang/swe-team
/path/to/swe-team/scripts/install.sh /path/to/your-project
```

Open Claude Code inside your project, then:

```
/swe-team-setup          ← guided wizard, ~2 min, no JSON editing
/swe-team "your feature" ← ship it
```

---

## Learn more

| Topic | Doc |
|---|---|
| Full pipeline breakdown | [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) |
| Connect Notion / Confluence / local vault | [docs/KNOWLEDGE-VAULT.md](docs/KNOWLEDGE-VAULT.md) |
| Security + DoD gates | [docs/SAFETY.md](docs/SAFETY.md) |
| Configuration reference | [docs/CONFIGURATION.md](docs/CONFIGURATION.md) |
| Inspecting run artifacts | [docs/TELEMETRY.md](docs/TELEMETRY.md) |

---

MIT · [SPEC.md](SPEC.md) is the Single Source of Truth
