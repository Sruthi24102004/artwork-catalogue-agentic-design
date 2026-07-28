-- Agentic AI Document Processing — PostgreSQL Schema
-- Illustrative schema supporting Section 7 of the design document.

CREATE TABLE catalogues (
    catalogue_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename        TEXT NOT NULL,
    uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    page_count      INTEGER NOT NULL,
    status          TEXT NOT NULL DEFAULT 'processing'
                        CHECK (status IN ('processing', 'completed', 'failed'))
);

CREATE TABLE pages (
    page_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    catalogue_id    UUID NOT NULL REFERENCES catalogues(catalogue_id),
    page_number     INTEGER NOT NULL,
    classification  TEXT
                        CHECK (classification IN ('artwork', 'cover', 'index', 'blank', 'other')),
    status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'classified', 'extracted', 'scored',
                                           'in_review', 'approved', 'rejected', 'skipped')),
    UNIQUE (catalogue_id, page_number)
);

CREATE TABLE artists (
    artist_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_name  TEXT NOT NULL UNIQUE,
    aliases         TEXT[]
);

CREATE TABLE artworks (
    artwork_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id         UUID NOT NULL REFERENCES pages(page_id),
    artist_id       UUID REFERENCES artists(artist_id),
    title           TEXT,
    medium          TEXT,
    dimensions      TEXT,
    estimate_low    NUMERIC(12, 2),
    estimate_high   NUMERIC(12, 2),
    currency        TEXT DEFAULT 'USD',
    image_url       TEXT,
    lot_number      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Audit trail of every AI extraction attempt, independent of whether it was approved.
CREATE TABLE extraction_runs (
    run_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id         UUID NOT NULL REFERENCES pages(page_id),
    skill_name      TEXT NOT NULL,
    skill_version   TEXT NOT NULL,
    raw_output      JSONB NOT NULL,
    confidence      NUMERIC(4, 3),
    run_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Audit trail of human review decisions.
CREATE TABLE review_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artwork_id      UUID NOT NULL REFERENCES artworks(artwork_id),
    reviewer        TEXT NOT NULL,
    action          TEXT NOT NULL
                        CHECK (action IN ('approved', 'edited', 'rejected')),
    field_diffs     JSONB,          -- e.g. {"title": {"before": "...", "after": "..."}}
    reviewed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pages_catalogue   ON pages (catalogue_id);
CREATE INDEX idx_artworks_page     ON artworks (page_id);
CREATE INDEX idx_artworks_artist   ON artworks (artist_id);
CREATE INDEX idx_extraction_page   ON extraction_runs (page_id);
CREATE INDEX idx_review_artwork    ON review_events (artwork_id);
