CREATE TABLE IF NOT EXISTS mp_groups (
    id text PRIMARY KEY, owner_id text NOT NULL REFERENCES mp_profiles, name text NOT NULL
);
CREATE TABLE IF NOT EXISTS mp_group_members (
    group_id text NOT NULL REFERENCES mp_groups ON DELETE CASCADE, user_id text NOT NULL REFERENCES mp_profiles,
    PRIMARY KEY(group_id,user_id)
);
CREATE INDEX IF NOT EXISTS mp_group_members_user ON mp_group_members(user_id,group_id);
CREATE TABLE IF NOT EXISTS mp_group_grants (
    group_id text NOT NULL REFERENCES mp_groups ON DELETE CASCADE, resource text NOT NULL REFERENCES mp_resources,
    actions text[] NOT NULL, policy jsonb NOT NULL, PRIMARY KEY(group_id,resource)
);
CREATE INDEX IF NOT EXISTS mp_group_grants_resource ON mp_group_grants(resource);

-- An empty source is a direct grant. Each expanded group grant has its own
-- usage ledger so removing one source cannot reset or revoke another.
ALTER TABLE mp_children ADD COLUMN IF NOT EXISTS grant_source text NOT NULL DEFAULT '';
ALTER TABLE mp_grants ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT '';
ALTER TABLE mp_grant_limits ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT '';
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_constraint WHERE conrelid='mp_grants'::regclass
               AND contype='p' AND cardinality(conkey)=2) THEN
        ALTER TABLE mp_grant_limits DROP CONSTRAINT mp_grant_limits_resource_grantee_fkey;
        ALTER TABLE mp_grant_limits DROP CONSTRAINT mp_grant_limits_pkey;
        ALTER TABLE mp_grants DROP CONSTRAINT mp_grants_pkey;
        ALTER TABLE mp_grants ADD PRIMARY KEY(resource,grantee,source);
        ALTER TABLE mp_grant_limits ADD PRIMARY KEY(resource,grantee,source,action);
        ALTER TABLE mp_grant_limits ADD FOREIGN KEY(resource,grantee,source)
            REFERENCES mp_grants(resource,grantee,source) ON DELETE CASCADE;
    END IF;
END $$;

-- The device checks the sealed request/run reference and its originating peer.
-- The relay checks the follow-up grant and its expiry without debiting a use.
CREATE OR REPLACE FUNCTION mp_action_spends_use(action text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT action NOT IN ('agent.status','agent.result','thread.read','thread.comment')
$$;

-- Pick a complete policy for an action. Never combine one source's higher
-- budget with another source's later expiration or automatic approval.
CREATE OR REPLACE VIEW mp_selected_grant_actions AS
SELECT DISTINCT ON (resource,grantee,action) *
FROM (
    SELECT g.resource,g.grantee,a.action,g.source,g.per_action,
        CASE WHEN g.per_action THEN l.expires_at ELSE g.expires_at END AS expires_at,
        CASE WHEN g.per_action THEN l.max_uses ELSE g.max_uses END AS max_uses,
        CASE WHEN g.per_action THEN l.used ELSE g.used END AS used,
        CASE WHEN g.per_action THEN l.approval ELSE 'ask' END AS approval,
        CASE WHEN g.per_action THEN l.budget_tokens ELSE 0 END AS budget_tokens,
        CASE WHEN g.per_action THEN l.attribution ELSE 'owner' END AS attribution
    FROM mp_grants g JOIN mp_resources r ON r.id=g.resource CROSS JOIN LATERAL unnest(g.actions) AS a(action)
    LEFT JOIN mp_grant_limits l ON (l.resource,l.grantee,l.source,l.action)=(g.resource,g.grantee,g.source,a.action)
    WHERE (g.source='' AND EXISTS (SELECT FROM mp_friends f
               WHERE f.a=least(r.owner_id,g.grantee) AND f.b=greatest(r.owner_id,g.grantee) AND f.accepted))
       OR (g.source<>'' AND EXISTS (SELECT FROM mp_group_grants t
               JOIN mp_group_members recipient ON recipient.group_id=t.group_id AND recipient.user_id=g.grantee
               JOIN mp_group_members owner ON owner.group_id=t.group_id AND owner.user_id=r.owner_id
               WHERE t.group_id=g.source AND t.resource=g.resource))
) candidates
ORDER BY resource,grantee,action,(expires_at>statement_timestamp() AND (used<max_uses OR NOT mp_action_spends_use(action))) DESC NULLS LAST, source;
CREATE OR REPLACE VIEW mp_effective_actions AS
SELECT resource,grantee,action,expires_at,max_uses,used FROM mp_selected_grant_actions;
CREATE OR REPLACE VIEW mp_available_actions AS
SELECT * FROM mp_selected_grant_actions
WHERE expires_at>statement_timestamp() AND (used<max_uses OR NOT mp_action_spends_use(action));
