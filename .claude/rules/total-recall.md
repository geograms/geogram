# Total Recall Protocol

> Auto-loaded every session. Defines memory system behavior.

## On Session Start
1. Read `AGENTS.md` for canonical repository instructions.
2. CLAUDE.local.md is auto-loaded (working memory).
3. Check `memory/registers/open-loops.md` for active follow-ups.
4. Check today's daily log exists; create if missing.

## During Session
- Capture noteworthy items to `memory/daily/[today].md`.
- Apply the **write gate**: "Does this change future behavior?" If no, skip.
- Route writes using the routing table in `memory/SCHEMA.md`.
- Keep repo-global workflow and architecture rules in `AGENTS.md`; use memory files for session continuity, preferences, and durable facts that are not already codified there.
- Never silently overwrite — use the contradiction protocol.

## On Session End
- Review daily log for register promotion candidates.
- Update open-loops register.
- Trim working memory if over ~1500 words.

## Commands
- `/recall-write <note>` — Save to daily log (and route if appropriate).
- `/recall-search <query>` — Search across all memory tiers.
- `/recall-status` — Check memory system health.
- `/recall-promote` — Promote daily log entries to registers.
- `/recall-maintain` — Verify stale entries, archive old logs.
