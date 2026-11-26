ALTER TABLE mp_resources ADD COLUMN IF NOT EXISTS listed boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS mp_resources_listed ON mp_resources (owner_id) WHERE listed;

CREATE TABLE IF NOT EXISTS mp_knowledge (
    id text PRIMARY KEY, owner_id text NOT NULL REFERENCES mp_profiles,
    version integer NOT NULL CHECK (version > 0)
);
CREATE TABLE IF NOT EXISTS mp_knowledge_versions (
    item text NOT NULL REFERENCES mp_knowledge, version integer NOT NULL,
    kind text NOT NULL CHECK (kind IN ('prompt','skill','instructions','mcp','summary')),
    name text NOT NULL, content text NOT NULL,
    scope text NOT NULL CHECK (scope IN ('private','friend','group','server')),
    target text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (item,version), CHECK ((scope IN ('friend','group')) = (target <> ''))
);

-- Existing children have no recorded start time. Count their completions and
-- omit unknown durations from the median.
ALTER TABLE mp_children ADD COLUMN IF NOT EXISTS submitted_at timestamptz;
ALTER TABLE mp_children ALTER COLUMN submitted_at SET DEFAULT now();
ALTER TABLE mp_children ADD COLUMN IF NOT EXISTS completed_at timestamptz;
CREATE INDEX IF NOT EXISTS mp_children_by_resource_sender ON mp_children(resource,sender);
CREATE TABLE IF NOT EXISTS mp_outcomes (
    child text PRIMARY KEY REFERENCES mp_children ON DELETE CASCADE, accepted boolean NOT NULL
);
CREATE TABLE IF NOT EXISTS mp_endorsements (
    resource text NOT NULL REFERENCES mp_resources, endorser text NOT NULL REFERENCES mp_profiles,
    skill text NOT NULL, PRIMARY KEY(resource,endorser,skill)
);
