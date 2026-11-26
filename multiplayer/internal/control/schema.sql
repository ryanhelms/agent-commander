CREATE TABLE IF NOT EXISTS mp_profiles (
    user_id text PRIMARY KEY, handle text UNIQUE
);
-- A member can set a profile or presence before choosing a discoverable handle.
ALTER TABLE mp_profiles ALTER COLUMN handle DROP NOT NULL;
ALTER TABLE mp_profiles ADD COLUMN IF NOT EXISTS display_name text NOT NULL DEFAULT '';
ALTER TABLE mp_profiles ADD COLUMN IF NOT EXISTS status_message text NOT NULL DEFAULT '';
ALTER TABLE mp_profiles ADD COLUMN IF NOT EXISTS presence text NOT NULL DEFAULT 'online'
    CHECK (presence IN ('online','away','busy','dnd'));
ALTER TABLE mp_profiles ADD COLUMN IF NOT EXISTS avatar bytea;
ALTER TABLE mp_profiles ADD COLUMN IF NOT EXISTS avatar_type text;
CREATE TABLE IF NOT EXISTS mp_friends (
    a text NOT NULL REFERENCES mp_profiles, b text NOT NULL REFERENCES mp_profiles,
    requester text NOT NULL, accepted boolean NOT NULL DEFAULT false,
    PRIMARY KEY (a,b), CHECK (a < b AND requester IN (a,b))
);
CREATE TABLE IF NOT EXISTS mp_leases (
    device text PRIMARY KEY, owner_id text NOT NULL, edge text NOT NULL,
    session text NOT NULL, generation bigint NOT NULL, expires_at timestamptz NOT NULL,
    ready boolean NOT NULL
);
ALTER TABLE mp_leases ADD COLUMN IF NOT EXISTS last_seen timestamptz;
CREATE INDEX IF NOT EXISTS mp_leases_owner ON mp_leases(owner_id);
CREATE TABLE IF NOT EXISTS mp_resources (
    id text PRIMARY KEY, owner_id text NOT NULL REFERENCES mp_profiles, device text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('agent','repo')), name text NOT NULL, actions text[] NOT NULL
);
ALTER TABLE mp_resources ADD COLUMN IF NOT EXISTS capabilities jsonb;
CREATE TABLE IF NOT EXISTS mp_access_requests (
    id text PRIMARY KEY, resource text NOT NULL REFERENCES mp_resources,
    requester text NOT NULL REFERENCES mp_profiles, actions text[] NOT NULL, note text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','granted'))
);
CREATE INDEX IF NOT EXISTS mp_access_requests_by_resource ON mp_access_requests(resource,requester);
CREATE INDEX IF NOT EXISTS mp_access_requests_by_requester ON mp_access_requests(requester);
CREATE TABLE IF NOT EXISTS mp_grants (
    resource text NOT NULL REFERENCES mp_resources, grantee text NOT NULL REFERENCES mp_profiles,
    actions text[] NOT NULL, expires_at timestamptz NOT NULL, max_uses bigint NOT NULL CHECK (max_uses > 0),
    used bigint NOT NULL DEFAULT 0, PRIMARY KEY (resource,grantee)
);
ALTER TABLE mp_grants ADD COLUMN IF NOT EXISTS per_action boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS mp_grant_limits (
    resource text NOT NULL, grantee text NOT NULL, action text NOT NULL,
    expires_at timestamptz, max_uses bigint CHECK (max_uses > 0),
    used bigint NOT NULL DEFAULT 0, PRIMARY KEY (resource,grantee,action),
    FOREIGN KEY (resource,grantee) REFERENCES mp_grants ON DELETE CASCADE
);
ALTER TABLE mp_grant_limits ADD COLUMN IF NOT EXISTS approval text NOT NULL DEFAULT 'ask'
    CHECK (approval IN ('ask','auto'));
ALTER TABLE mp_grant_limits ADD COLUMN IF NOT EXISTS budget_tokens bigint NOT NULL DEFAULT 0
    CHECK (budget_tokens >= 0);
ALTER TABLE mp_grant_limits ADD COLUMN IF NOT EXISTS attribution text NOT NULL DEFAULT 'owner'
    CHECK (attribution IN ('owner','requester'));
CREATE OR REPLACE VIEW mp_effective_actions AS
SELECT g.resource,g.grantee,a.action,
    CASE WHEN g.per_action THEN l.expires_at ELSE g.expires_at END AS expires_at,
    CASE WHEN g.per_action THEN l.max_uses ELSE g.max_uses END AS max_uses,
    CASE WHEN g.per_action THEN l.used ELSE g.used END AS used
FROM mp_grants g CROSS JOIN LATERAL unnest(g.actions) AS a(action)
LEFT JOIN mp_grant_limits l ON (l.resource,l.grantee,l.action)=(g.resource,g.grantee,a.action);
CREATE TABLE IF NOT EXISTS mp_submissions (
    sender text NOT NULL, parent text NOT NULL, sender_device text NOT NULL, digest bytea NOT NULL,
    PRIMARY KEY (sender,parent)
);
CREATE TABLE IF NOT EXISTS mp_children (
    id text PRIMARY KEY, parent text NOT NULL, sender text NOT NULL, sender_device text NOT NULL,
    owner_id text NOT NULL, device text NOT NULL, resource text NOT NULL REFERENCES mp_resources,
    action text NOT NULL, envelope jsonb NOT NULL, expires_at timestamptz NOT NULL, status text NOT NULL,
    result jsonb, FOREIGN KEY (sender,parent) REFERENCES mp_submissions(sender,parent),
    UNIQUE (sender,parent,resource,action)
);
CREATE TABLE IF NOT EXISTS mp_outbox (
    id text PRIMARY KEY REFERENCES mp_children, published boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS mp_outbox_pending ON mp_outbox(id) WHERE NOT published;
CREATE INDEX IF NOT EXISTS mp_leases_by_owner ON mp_leases(owner_id,expires_at) WHERE ready;
CREATE INDEX IF NOT EXISTS mp_friends_by_b ON mp_friends(b,a);
CREATE INDEX IF NOT EXISTS mp_resources_by_owner ON mp_resources(owner_id,device);
CREATE INDEX IF NOT EXISTS mp_grants_by_grantee ON mp_grants(grantee,expires_at);
CREATE INDEX IF NOT EXISTS mp_children_by_recipient ON mp_children(device,expires_at,id) WHERE status='pending';
CREATE INDEX IF NOT EXISTS mp_children_pending_by_sender_device ON mp_children(sender_device) WHERE status='pending';
CREATE INDEX IF NOT EXISTS mp_children_pending_by_grant ON mp_children(resource,sender) WHERE status='pending';
CREATE INDEX IF NOT EXISTS mp_children_by_sender_parent ON mp_children(sender,parent,id);
