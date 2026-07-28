# Agentic AI Document Processing — Design Document

**System:** Artwork Catalogue Extraction with Human-in-the-Loop Validation
**Scope:** System design only — no implementation

---

## 1. Problem Summary

An auction house uploads a ~50-page PDF artwork catalogue. Each page may contain zero, one, or several artwork lots — an image plus metadata such as artist, title, medium, dimensions, and estimate range. The system must turn this unstructured PDF into structured, human-verified rows in PostgreSQL, using AI to do the heavy lifting and a human reviewer as the final quality gate before anything is persisted.

The design goal is not "call an LLM on each page" — it's a **modular pipeline** where autonomous **Agents** decide what needs to happen next, and stateless **Skills** do the actual computation. This separation is what makes the system testable, swappable, and scalable independent of any one AI provider.

---

## 2. Overall Architecture

At the highest level, four layers sit between the uploaded PDF and the database (see Diagram 1 — System Overview):

- **Ingestion layer** — accepts the PDF, splits it into pages, stores raw page images/text in object storage (e.g. S3), and creates a job record.
- **Agent orchestration layer** — a set of coordinating agents that plan and drive the workflow, retry failed steps, and track job/page state.
- **AI Skills layer** — reusable, stateless functions (OCR, image extraction, metadata parsing, entity matching, confidence scoring) that agents call. Skills know nothing about the workflow; they just take an input and return an output.
- **Human-in-the-loop (HITL) layer** — a review queue and UI where a human approves or corrects extracted records before they're committed.
- **Persistence layer** — PostgreSQL, holding both the final structured artwork data and the audit trail of how it got there.

The system is designed as an **event-driven pipeline**, not a single long-running function call. Each page (and later, each artwork record) moves through discrete states (`uploaded → classified → extracted → scored → in_review → approved/rejected → saved`), tracked in the database, so the orchestrator can resume, retry, or parallelize work at the page level rather than treating the whole 50-page catalogue as one atomic unit. This matters directly for scalability (Section 8) — pages are processed independently and in parallel.

Agents communicate via a task queue (e.g. SQS/RabbitMQ) rather than direct function calls, so any agent or skill can be scaled, replaced, or retried independently of the others.

---

## 3. Agent Responsibilities

Agents are the **decision-makers**. Each agent owns a slice of the workflow and decides what to do next based on state — it does not itself perform OCR or parse text; it delegates that to a Skill (Diagram 2 — Agents vs. Skills). Four agents are proposed:

| Agent | Responsibility | Decides |
|---|---|---|
| **Orchestrator Agent** | Owns the overall job lifecycle for a catalogue. Splits work into per-page tasks, tracks progress, handles retries and failures, and marks a job complete once every page has reached a terminal state. | "What page/task runs next? Has this job stalled? Should this step be retried?" |
| **Extraction Agent** | For each page flagged as containing artwork, coordinates calling the OCR, image-extraction, and metadata-parsing skills, and merges their outputs into a draft artwork record. | "Which skills does this page need? Is the draft record complete enough to score?" |
| **Validation Agent** | Runs confidence scoring and entity matching (e.g. matching an artist name against a known-artist reference table) on each draft record, and decides whether it can be auto-approved or must be routed to a human. | "Is this record trustworthy enough to skip human review?" |
| **Persistence Agent** | Takes an approved (human- or auto-) record and writes it to PostgreSQL inside a transaction, along with its provenance (which skill versions produced it, reviewer identity, timestamps). | "Is this record safe to commit? Does it conflict with an existing row?" |

The Orchestrator is the only agent aware of the *whole* job; the others are scoped to a single page or record, which keeps them simple, stateless between invocations, and independently scalable (you can run many Extraction Agent workers in parallel across pages).

---

## 4. AI Skills and Their Interactions

Skills are the **computation layer** — narrow, reusable, and stateless. They take a well-defined input and return a well-defined output, with no awareness of the broader workflow. This is deliberate: it means any skill can be swapped (e.g. switching OCR providers) without touching agent logic, and skills can be unit-tested in isolation.

| Skill | Input | Output | Notes |
|---|---|---|---|
| **Page Classification Skill** | Page image | Label: contains-artwork / cover-page / index-page / blank | Cheap vision/text classifier; filters out non-artwork pages early to save downstream cost |
| **OCR Skill** | Page image | Raw text blocks with bounding boxes | Handles printed catalogue text; layout-aware (columns, captions) |
| **Image Extraction Skill** | Page image + layout | Cropped artwork image(s) | Separates the artwork photo from surrounding text/caption |
| **Metadata Extraction Skill** | OCR text for a lot | Structured fields: artist, title, medium, dimensions, estimate, lot number | LLM-based structured extraction (e.g. schema-constrained JSON output) |
| **Entity Matching Skill** | Extracted artist/medium strings | Matched reference ID + match score | Resolves "Pablo Picasso" vs. "P. Picasso" against a canonical artist table |
| **Confidence Scoring Skill** | Draft record + source evidence | Per-field confidence score (0–1) | Combines OCR confidence, extraction model confidence, and entity-match score |

**Interaction pattern:** the Extraction Agent calls Page Classification → (if artwork) OCR + Image Extraction in parallel → Metadata Extraction on the OCR output. The Validation Agent then calls Entity Matching and Confidence Scoring on the draft record. No skill calls another skill directly — all sequencing is done by the agent, which keeps the dependency graph explicit and visible in one place rather than hidden inside skill code.

---

## 5. End-to-End Workflow

(See Diagram 3 — Workflow, for the visual sequence.)

1. **Split pages** — the PDF is decomposed into individual page images/text by the Ingestion layer; a job and per-page task records are created.
2. **Classify page** — the Orchestrator dispatches each page to the Page Classification Skill via the Extraction Agent; non-artwork pages are marked done and skipped.
3. **Extract data** — for artwork pages, the Extraction Agent runs OCR, image extraction, and metadata extraction, producing a draft record.
4. **Score confidence** — the Validation Agent runs entity matching and confidence scoring on the draft.
5. **Human review (conditional)** — records below a confidence threshold, or with unmatched entities, are routed to a reviewer queue; high-confidence records can be auto-approved (see Section 6).
6. **Save to PostgreSQL** — the Persistence Agent commits the approved record, along with the image reference and an audit trail of scores and any human edits.

Pages are processed independently, so a slow or failed page never blocks the rest of the catalogue — this is the main scalability lever in the design.

---

## 6. Human-in-the-Loop Workflow

(See Diagram 4 — HITL Decision Logic.)

Human review is **confidence-gated, not universal** — reviewing all 50+ records on every catalogue doesn't scale, but reviewing none defeats the point of HITL. The Validation Agent applies a threshold per field (e.g. artist name, dimensions, estimate) rather than per record, since a record can be mostly correct but wrong on one field:

- **High confidence on all required fields** → auto-approved, written directly to PostgreSQL, but still logged for periodic audit sampling.
- **Any field below threshold, or an unmatched entity** → the whole record is routed to a review queue.

**Reviewer experience:** the reviewer sees the cropped artwork image side-by-side with the extracted fields, with low-confidence fields visually flagged. They can accept, edit, or reject the record. Edits are captured as corrections (not silent overwrites) — this correction history is valuable both as an audit trail and as future fine-tuning/prompt-improvement data.

- **Accept** → Persistence Agent commits as-is.
- **Edit + Accept** → Persistence Agent commits the corrected version; the original AI output and the correction are both stored.
- **Reject** → record is flagged for reprocessing or manual entry; does not enter PostgreSQL.

This keeps the human in the loop exactly where AI confidence is weakest, rather than as a blanket bottleneck.

---

## 7. Data Flow into PostgreSQL

Only **approved** records are written — nothing from the extraction stage is persisted directly to the production tables, which keeps the "source of truth" clean of unreviewed AI output.

Proposed core tables (illustrative, not exhaustive):

- `catalogues` — one row per uploaded PDF (filename, upload time, page count, status)
- `pages` — one row per page (catalogue_id, page_number, classification, status)
- `artworks` — one row per approved artwork record (page_id, artist_id, title, medium, dimensions, estimate_low, estimate_high, image_url)
- `artists` — canonical artist reference table, used by the Entity Matching Skill
- `review_events` — audit log of every human decision (artwork_id, reviewer, action, field-level diffs, timestamp)
- `extraction_runs` — audit log of skill versions/models and confidence scores used to produce each draft, for traceability

The Persistence Agent writes `artworks` and `review_events` in a single transaction, so a record and its approval history are never out of sync. `extraction_runs` is written earlier (at extraction time) so that even rejected records leave a trace for debugging model quality.

---

## 8. Assumptions, Trade-offs, and Technology Choices

**Assumptions**
- Catalogues are digitally generated or high-quality scanned PDFs (OCR accuracy assumptions would need revisiting for poor-quality scans).
- One artwork "lot" per page on average, though the design tolerates multiple lots per page since extraction operates on detected regions, not whole pages.
- Human reviewers are domain-literate (can recognize an obviously wrong artist match) but are not expected to re-key data from scratch.

**Trade-offs**
- **Confidence-gated HITL vs. full review**: reduces reviewer workload significantly but introduces risk of auto-approving a subtly wrong field. Mitigated by periodic random-sample auditing of auto-approved records.
- **Per-page parallelism vs. cross-page context**: processing pages independently maximizes throughput and fault isolation, but loses context for lots that span two pages (e.g. a description continuing on the next page). Addressed by a lightweight page-adjacency check in the Extraction Agent rather than merging pages upfront.
- **Stateless skills vs. cost**: keeping skills stateless (no shared memory between calls) is simpler and more scalable, at the cost of repeating context (e.g. re-sending catalogue-level formatting hints) in every skill call.

**Technology choices (representative, not prescriptive)**
- **PostgreSQL** over a document store: artwork records are relational (artists, provenance, review history all reference each other) and benefit from constraints/transactions; JSONB columns can still hold flexible/raw extraction output where needed.
- **Message queue between agents** (SQS/RabbitMQ) over direct calls: decouples agents, allows independent scaling of extraction vs. validation workload, and gives natural retry/dead-letter handling for failed pages.
- **Object storage (S3) for images/PDFs**, with PostgreSQL storing references, not binary blobs — keeps the database lean and cacheable/CDN-friendly for the review UI.
- **LLM-based structured extraction** (schema-constrained JSON output) for metadata parsing, since catalogue formatting varies enough that regex/rule-based parsing would be brittle across auction houses.

---

## 9. Failure Handling and Security

**Retries and failure escalation.** Each skill call made by an agent is wrapped with a bounded retry policy (e.g. 3 attempts with exponential backoff) to absorb transient failures such as a rate-limited API or a momentary network error. If a page task exhausts its retries, the Orchestrator Agent does not retry indefinitely or silently drop it — the task is moved to a dead-letter queue and the page is marked `failed` in the database, visible on the job status view. Failed pages do not block the rest of the catalogue from completing, and can be manually re-queued or routed to manual entry once the underlying cause (e.g. a corrupted page image) is fixed. This keeps failure containment at the page level, consistent with the rest of the design's per-page independence.

**Security and data handling.** Catalogue data is generally not sensitive (public auction listings), but the pipeline still touches two categories worth securing: uploaded source PDFs/images, and reviewer identity captured in the audit trail. Object storage (S3) and the database are access-controlled and not public by default; the review UI sits behind authentication so only authorized reviewers can approve or edit records, and every `review_events` row ties an action to a specific reviewer for accountability. If a future catalogue contains any consignor or buyer personal information, that data would need to be scoped out of the general-purpose `artworks` table and handled with stricter access controls — the current schema assumes catalogue-level (not personal) data only.

---

## 10. Scalability and Maintainability

- **Horizontal scaling**: because pages are independent units of work on a queue, adding more Extraction Agent workers directly increases throughput for larger catalogues (e.g. 500-page catalogues, or many catalogues uploaded concurrently).
- **Swappable skills**: since skills are stateless and agent-agnostic, a better OCR provider or a fine-tuned extraction model can be swapped in behind the same skill interface without changing any agent.
- **Observability**: per-page and per-skill state transitions are all recorded, so a stalled or failing catalogue can be diagnosed at the page/skill level rather than as an opaque end-to-end failure.
- **Extensibility**: new skills (e.g. a provenance/condition-report extraction skill) can be added and wired into the Extraction Agent without restructuring the orchestration layer.

---

## 11. Summary

The design separates **orchestration** (Agents deciding what happens next) from **computation** (Skills doing the actual AI work), connects them through a queue-driven, per-page state machine, and inserts a human reviewer only where AI confidence is genuinely low. This keeps the system modular — any single piece (an OCR provider, a confidence threshold, a review UI) can change without a cascading redesign — while still producing a clean, auditable, human-verified dataset in PostgreSQL.
