---
name: slack-summary
description: Summarize recent Slack activity across all channels, categorized by relevance for a Head of Engineering. Use when the user asks "what happened in slack", "summarize slack", "slack digest", "catch me up on slack", or similar.
argument-hint: [since <date|"yesterday"|"today">]
allowed-tools: [mcp__claude_ai_Slack__slack_search_public_and_private, mcp__claude_ai_Slack__slack_search_channels, mcp__claude_ai_Slack__slack_read_channel, mcp__claude_ai_Slack__slack_read_thread, Read]
---

# Slack Summary Skill

Produce a concise, aggressively categorized digest of Slack activity for the user (Head of Engineering). Signal-to-noise is the goal — surface what needs action, note what's informational, and explicitly discard fluff.

---

## Step 0 — Load Local Context

Read `~/.claude/skills/slack-summary/context.local.md` if it exists. It contains company-specific context: org name, key channel names, team member names, customer names, and any standing priorities. Use this to calibrate relevance and attribution throughout the summary. If the file doesn't exist, proceed with defaults and infer context from messages.

---

## Step 1 — Determine the Time Window

Parse the argument or user message for a date/range:
- "since yesterday" → `after:YYYY-MM-DD` using yesterday's date
- "today" → `after:YYYY-MM-DD` using today's date
- explicit date → use it directly

Default to **yesterday** if no time is given.

---

## Step 2 — Gather Messages

Run these in parallel:

### 2a — Broad search across all channels
```
query: "after:YYYY-MM-DD"
sort: timestamp
sort_dir: desc
limit: 20
include_bots: false
channel_types: public_channel,private_channel,mpim,im
response_format: concise
```

Paginate through at least **4–5 pages** (cursor-based) to capture the full day.

### 2b — Find channels that were active
Use `slack_search_channels` with broad queries ("engineering", "general", "cs", "product", "alerts", "project", "roadmap") to collect channel IDs for any channels not appearing in search results.

### 2c — Read key channels directly
For high-signal channels (eng-general, alerts, pull-requests, cs-general, product, project-* — or equivalents from context.local.md), use `slack_read_channel` with `oldest` set to the start of the window. Read up to 100 messages per channel.

### 2d — Targeted searches for roadmap/product/customer signals
Run these additional keyword searches in parallel:
- `"roadmap feature request after:YYYY-MM-DD"` — explicit roadmap or feature asks
- `"customer feedback request after:YYYY-MM-DD"` — customer pain points
- `"adoption usage onboarding after:YYYY-MM-DD"` — product adoption signals
- `"deploy release ship after:YYYY-MM-DD"` — shipping activity beyond pull-requests channel

---

## Step 3 — Synthesize the Summary

Organize output into these sections. Be ruthless about what goes where.

### 🔴 Action Required / Blockers
Customer-facing bugs, broken syncs, infra incidents, anything blocking a teammate or a customer. For each item:
- What happened
- Who's involved / current owner
- Whether it's resolved or still open
- What action is needed from the Head of Engineering

### 🟡 Engineering Progress
Work-in-progress updates from engineers. Use a table:
| Engineer | What they're working on |

Also list PRs shipped in the window (number + one-line description).

### 🟡 Decisions / Discussions Needing Awareness
Architecture discussions, permission/scope debates, feature flag questions, cross-team asks that may require eng judgment. Brief bullets.

### 🟠 Roadmap & Product Signals
Things that should feed into engineering planning or the product roadmap. Look for:
- Feature requests from customers (direct or relayed by CS/sales)
- Recurring pain points or complaints about specific product areas
- Team ideas with eng implications ("we should build", "customers keep asking")
- Adoption blockers: reasons customers aren't using a feature or workflow

One bullet per signal, include source (who said it, which channel, which customer if known).

### 🟢 Product Adoption & Customer Health
Signals about how customers are actually using the product — not bugs, but usage patterns, onboarding friction, expansion signals, churn risk. Brief bullets, flag customer name when known.

### ⚫ Irrelevant (Skipped)
A single line listing channels/topics skipped and why (e.g. pipeline banter, SDR activity, social chat, industry links).

---

## Step 4 — Closing Summary

1. **Top priority today** — one sentence on the most urgent 🔴 item.
2. **Roadmap / planning note** — one sentence on the most actionable 🟠 signal worth a ticket or bringing to the next planning session.

---

## Tone & Format Rules

- No emoji spam — use the colored circles only for section headers
- Tables for engineer status, bullets for everything else
- Never explain what Slack is or how the search worked
- If a thread is referenced and context is unclear, use `slack_read_thread` before summarizing
- Attribute messages to names, not user IDs
- Skip bot messages entirely
- If the window is empty or very quiet, say so in one line — don't pad
