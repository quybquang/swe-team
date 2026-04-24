---
name: swe-team:onboard
description: >
  Interactive setup wizard for swe-team. Walks the user through all configuration
  questions in their chosen language, then writes swe-team.config.json for them.
  No JSON editing required. Invoke via /swe-team-setup command.
---

# Onboard

## Overview

`swe-team:onboard` is a conversational setup wizard. It asks the user one question at a
time, in their chosen language, and writes `swe-team.config.json` on their behalf. The
user never touches a config file manually.

Run this skill whenever a teammate is setting up swe-team for the first time, or when
they want to reconfigure an existing install. The skill is fully idempotent: running it
again overwrites only the config file, nothing else.

## When to Use

- `/swe-team-setup` is invoked (first-time or reconfigure).
- A teammate reports confusion about configuration.
- A project's stack, branch, or knowledge source has changed.

## When NOT to Use

- The run is already in progress (`run.json` exists with `status: running`). Do not reconfigure mid-run.
- You are inside a spawned subagent context. This skill requires the main thread (user interaction).

## Process

Work through the sections below **strictly in order**. Ask one section at a time.
After each answer, confirm what you understood before moving on.
Use short, friendly sentences — not technical jargon.
Never show raw JSON to the user until the final confirmation step.

---

### Section 0 — Language

Before anything else, ask:

> "What language would you like to use for this setup?
> (e.g. English, Tiếng Việt, 日本語, Español, ...)"

From this point forward, conduct ALL communication in the language the user chose.
If the user types a language you know, switch immediately.

---

### Section 1 — Detect project (auto, confirm)

Run detection silently:

```bash
# Stack
[ -f package.json ] && cat package.json | jq -r '.scripts | {test,lint,typecheck}' 2>/dev/null
[ -f go.mod ] && echo "go"
[ -f pyproject.toml ] || [ -f requirements.txt ] && echo "python"

# Package manager
[ -f pnpm-lock.yaml ] && echo "pnpm"
[ -f yarn.lock ] && echo "yarn"
[ -f package-lock.json ] && echo "npm"

# Base branch
git branch -a | grep -E 'origin/(dev|develop|main|master)' | head -1
```

Then show the user a plain-language summary and ask one confirmation question. Example (in Vietnamese):

> "Tôi phát hiện dự án của bạn dùng **Node.js + pnpm**, branch chính là **dev**.
> Lệnh test: `pnpm test` | lint: `pnpm run lint` | typecheck: `pnpm run typecheck`
>
> Có đúng không? (Gõ 'đúng' để tiếp tục, hoặc sửa nếu cần)"

If the user corrects any value, note the correction and continue.
Never ask for test/lint/typecheck commands explicitly — auto-detect, then confirm.

---

### Section 2 — Base branch

If detection found a clear base branch, confirm it:

> "Branch mà PR sẽ được tạo vào là **dev**. Giữ nguyên không?"

If not found or ambiguous, ask:

> "PR của bạn nên được tạo vào branch nào? (thường là `dev`, `develop`, hoặc `main`)"

---

### Section 3 — Knowledge sources

Ask in plain language:

> "Nhóm của bạn có dùng công cụ lưu trữ tài liệu, quy trình nội bộ không?
> Ví dụ: thư mục wiki local, Notion, Confluence, Linear — hay là chưa có?"

Based on answer:

**If "local vault / thư mục local":**
> "Đường dẫn đến thư mục đó là gì? (ví dụ: ~/vault hoặc /Users/yourname/docs)"

> "Tên của dự án này trong thư mục đó là gì? (dùng để tạo đường dẫn wiki/projects/<tên>)"

Ask if they also want to write lessons back after each run:
> "Sau mỗi lần chạy, swe-team có thể tự ghi bài học vào thư mục đó.
> Bạn có muốn bật tính năng này không? (có / không)"

**If "Notion":**
> "Bạn có thể cho tôi biết ID của workspace hoặc database Notion không?
> (Tìm trong URL Notion của bạn — phần sau dấu `/`, trước dấu `?`)"

Ask capabilities: read only, or also write-back?

**If "Confluence":**
> "Space key của Confluence là gì? (thường là 2–5 chữ in hoa, ví dụ: ENG, PROD)"

Ask capabilities: read only, or also write-back?

**If "Linear":**
> "Tôi sẽ kết nối Linear để đọc ticket liên quan khi phân tích yêu cầu. (chỉ đọc)"
Set `capabilities: ["read"]`.

**If "none / chưa có":**
Note this and skip. `knowledge.sources = []`.

**Multiple sources:**
Ask for each source separately using the same flow above.
After all sources collected, ask which one should receive write-back (if any support write).

---

### Section 4 — Budget

Show defaults clearly, ask if they want to change:

> "Mỗi lần chạy, swe-team mặc định giới hạn **$15** và **2 triệu tokens**.
> Giữ nguyên không? (hoặc cho tôi biết giới hạn bạn muốn)"

Only ask further if they want to change.

---

### Section 5 — Security

Ask simply:

> "Khi phát hiện lỗ hổng bảo mật nghiêm trọng (ví dụ: SQL injection, lộ secret):
> - Chặn PR lại để sửa (khuyến nghị)
> - Hoặc chỉ cảnh báo trong nội dung PR
>
> Bạn chọn hướng nào?"

Map to:
- "Chặn PR" → `fail_on: ["critical", "high"]`
- "Chỉ cảnh báo" → `fail_on: []`, `warn_on: ["critical", "high", "medium"]`

---

### Section 6 — Clarification mode

Ask:

> "Trước khi code, swe-team thường tự phân tích yêu cầu và đưa ra giả định mà không hỏi bạn.
> Hay bạn muốn nó hỏi bạn 3–5 câu để xác nhận trước khi bắt đầu?
>
> - Tự xử lý (nhanh hơn, chạy không giám sát)
> - Hỏi tôi trước (chậm hơn nhưng chính xác hơn)"

Map to `clarify.mode: "autonomous" | "interactive"`.

---

### Section 7 — Write config

Now you have all answers. DO NOT show the raw JSON yet. Instead, show a plain-language summary:

> "Tôi sẽ cấu hình swe-team như sau:
>
> - Dự án: Node.js + pnpm | Branch: dev
> - Giới hạn: $15 / lần chạy
> - Bảo mật: Chặn PR nếu phát hiện lỗ hổng nghiêm trọng
> - Clarify: Tự động phân tích (không hỏi bạn)
> - Kho tri thức: ~/vault (đọc + ghi) · Notion abc123 (chỉ đọc)
>
> Xác nhận để tôi ghi cấu hình? (có / không)"

If confirmed, write `swe-team.config.json`:

```bash
cat > swe-team.config.json << 'ENDOFCONFIG'
{
  "$schema": "./.claude/references/config-schema.json",
  "version": "<VERSION from .claude/swe-team/VERSION>",
  "models": {
    "lead": "opus",
    "coder": "sonnet",
    "verifier_mech": "haiku",
    "verifier_sem": "sonnet",
    "pr": "sonnet"
  },
  "budget": { ... },
  "limits": { ... },
  "branch": { "base": "<detected>", "prefix": "swe/", "auto_detect_base": true },
  "verification": { "test_cmd": "<detected>", "lint_cmd": "<detected>", "typecheck_cmd": "<detected>", "test_globs": [...], "allow_flaky_retry": true },
  "clarify": { "enabled": true, "mode": "<autonomous|interactive>", "max_questions": 5 },
  "security": { "enabled": true, "fail_on": [...], "warn_on": [...] },
  "retro": { "enabled": true, "max_learnings_per_run": 5, "learnings_window": 10 },
  "phases": { "define_threshold": 3, "force_define": false, "skip_define": false, "skip_clarify": false },
  "gh": { "pr_labels": ["ai-generated", "swe-team"], "pr_draft": false, "require_clean_working_tree": true },
  "knowledge": { "sources": [...], "write_target": "..." }
}
ENDOFCONFIG
```

Fill in all values from the user's answers. Never use placeholder strings in the final file.

---

### Section 8 — Verify

After writing, run a quick validation:

```bash
python3 -c "
import json, sys
with open('swe-team.config.json') as f:
    json.load(f)
print('ok')
" 2>&1
```

If validation passes, tell the user:

> "Xong! `swe-team.config.json` đã được ghi.
>
> Bước tiếp theo:
> 1. Commit file này: `git add swe-team.config.json && git commit -m 'chore: configure swe-team'`
> 2. Thử chạy: `/swe-team "Thêm một tính năng nhỏ để test"`"

If validation fails, show the error in plain language and offer to fix it.

---

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "The user seems technical — I'll just show them the JSON." | Never show raw JSON unless they explicitly ask. The wizard exists precisely to abstract that away. |
| "I'll ask all questions at once to save time." | One section at a time. Dumping 10 questions at once is overwhelming and causes drop-off. |
| "I'll skip Section 3 if it seems complex." | Always ask about knowledge sources. A "none" answer is fine — but skipping the question means the user never knows the feature exists. |
| "I'll use sensible defaults and not ask." | Show the default and ask for confirmation. Silent defaults that are wrong waste the user's first run. |
| "The user said 'yes' so I'll assume they meant yes to everything." | Confirm each section separately. "Yes" to stack detection is not "yes" to budget limits. |

## Red Flags

- User doesn't know their Notion workspace ID — offer: "You can skip this for now and re-run `/swe-team-setup` later when you have it."
- User provides a vault path that doesn't exist yet — warn: "That path doesn't exist. Run `vault-init` first, or choose a different path."
- User changes their mind mid-wizard — restart the affected section, not the whole wizard.
- JSON validation fails after write — show the specific error field in plain language; never ask the user to "edit the JSON manually."

## Verification

After this skill completes:
- `swe-team.config.json` exists at repo root and is valid JSON.
- All required fields are populated (no `"auto"` values left unresolved unless intentional).
- The user has been given the two next-step commands.
- No raw JSON was shown to the user during the wizard (only in the final confirmation summary if they asked).
