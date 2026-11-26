-- Enrollment and control edges bootstrap these tables under the same lock.
SELECT pg_advisory_xact_lock(1466203104);
CREATE TABLE IF NOT EXISTS mp_members (
    user_id text PRIMARY KEY, contact_key text NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS mp_membership (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    mode text NOT NULL CHECK (mode IN ('open', 'allowlist', 'invite')),
    allowed_emails text[] NOT NULL, admins text[] NOT NULL
);
CREATE TABLE IF NOT EXISTS mp_invites (
    code text PRIMARY KEY, expires_at timestamptz NOT NULL,
    max_uses bigint NOT NULL CHECK (max_uses > 0),
    uses bigint NOT NULL DEFAULT 0 CHECK (uses BETWEEN 0 AND max_uses)
);

-- Identity receives verified email hashes, while the admin API edits addresses.
-- Derive the lookup sets from the settings so both see the same policy revision.
CREATE OR REPLACE VIEW mp_membership_policy AS
SELECT mode,
    ARRAY(SELECT encode(sha256(convert_to(email,'UTF8')),'hex')
          FROM unnest(allowed_emails || admins) AS email) AS allowed_hashes,
    ARRAY(SELECT encode(sha256(convert_to(email,'UTF8')),'hex')
          FROM unnest(admins) AS email) AS admin_hashes,
    allowed_emails, admins
FROM mp_membership;

CREATE TABLE IF NOT EXISTS mp_events (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recipient text NOT NULL, at timestamptz NOT NULL DEFAULT clock_timestamp(),
    kind text NOT NULL, actor text NOT NULL, resource text NOT NULL DEFAULT '', detail text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS mp_events_feed ON mp_events(recipient,seq);
CREATE INDEX IF NOT EXISTS mp_events_retention ON mp_events(at);

ALTER TABLE mp_members ADD COLUMN IF NOT EXISTS suspended boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS mp_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    knowledge_default text NOT NULL DEFAULT 'private' CHECK (knowledge_default IN ('private','friend','group','server')),
    knowledge_widest text NOT NULL DEFAULT 'server' CHECK (knowledge_widest IN ('private','friend','group','server')),
    reputation_visibility text NOT NULL DEFAULT 'owner' CHECK (reputation_visibility IN ('owner','users','friends','server')),
    directory boolean NOT NULL DEFAULT true,
    max_grant_days integer NOT NULL DEFAULT 0 CHECK (max_grant_days >= 0),
    max_budget_tokens bigint NOT NULL DEFAULT 0 CHECK (max_budget_tokens >= 0),
    retention_days integer NOT NULL DEFAULT 30 CHECK (retention_days > 0)
);
INSERT INTO mp_policy DEFAULT VALUES ON CONFLICT (singleton) DO NOTHING;
