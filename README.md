# Agentic AI Document Processing — Artwork Catalogue Extraction

System design for an Agentic AI pipeline that processes ~50-page artwork catalogue PDFs, extracts structured artwork records via AI Skills, validates them through Human-in-the-Loop review, and persists approved records to PostgreSQL.

This is a **system design exercise** — no implementation is included.

## Contents

- [`docs/design_document.md`](docs/design_document.md) — full design document: architecture, agent responsibilities, AI skills, HITL workflow, data flow, assumptions & trade-offs
- [`diagrams/`](diagrams) — five diagrams covering system overview, agents vs. skills, workflow, HITL logic, and the full detailed workflow
- [`schema/postgres_schema.sql`](schema/postgres_schema.sql) — PostgreSQL schema for catalogues, pages, artworks, artists, and audit trails
- [`schema/postgres_er_diagram.png`](schema/postgres_er_diagram.png) — ER diagram of the schema above

## Diagrams

The pipeline is broken into five standalone diagrams — a high-level system view, the agents/skills separation, the six-step workflow, the human-review decision logic, and a fully detailed end-to-end version tying agents, skills, and HITL together — plus a PostgreSQL ER diagram for the data model.

![System Overview](diagrams/01_system_overview.png)
![Agents vs Skills](diagrams/02_agents_vs_skills.jpeg)
![Workflow](diagrams/03_workflow.png)
![HITL Decision Logic](diagrams/04_hitl_logic.png)
![Full Workflow Detailed](diagrams/05_full_workflow_detailed.png)
![PostgreSQL ER Diagram](schema/postgres_er_diagram.png)

## Repository Structure

```
.
├── README.md
├── docs/
│   └── design_document.md
├── diagrams/
│   ├── 01_system_overview.png
│   ├── 02_agents_vs_skills.jpeg
│   ├── 03_workflow.png
│   ├── 04_hitl_logic.png
│   └── 05_full_workflow_detailed.png
└── schema/
    ├── postgres_schema.sql
    └── postgres_er_diagram.png
```
