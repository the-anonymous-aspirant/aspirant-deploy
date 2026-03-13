# Decision Log

Architectural decisions and their rationale. When revisiting a choice, check here first — the reasoning may still apply.

---

### {YYYY-MM-DD} — {Short title of the decision}

**Context:** {What situation or requirement prompted this decision?}

**Options considered:**
1. {Option A} — {tradeoff}
2. {Option B} — {tradeoff}

**Decision:** {Which option was chosen}

**Rationale:** {Why — reference values from DEVELOPMENT_PHILOSOPHY.md if applicable}

---

<!-- Example entry:

### 2026-03-09 — Whisper base model over small

**Context:** Choosing the Whisper model size for audio transcription on a home server with 8 GB total RAM.

**Options considered:**
1. `tiny` (39M params, ~500 MB) — Fast, low resource, but noticeably worse accuracy on non-English audio
2. `base` (74M params, ~1 GB) — Good accuracy/resource balance, handles multilingual well
3. `small` (244M params, ~2 GB) — Better accuracy, but consumes the full container memory budget

**Decision:** `base`

**Rationale:** Fits within the 2 GB container limit with headroom for the Python process and FFmpeg. Accuracy is sufficient for personal voice notes. Aligns with "slow and reliable over fast but hard to debug" — `tiny` would be faster but produce more transcription errors to debug.

-->
