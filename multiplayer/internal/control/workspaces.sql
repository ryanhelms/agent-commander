CREATE TABLE IF NOT EXISTS mp_workspaces (
    id text PRIMARY KEY, owner_id text NOT NULL REFERENCES mp_profiles,
    group_id text NOT NULL REFERENCES mp_groups ON DELETE CASCADE,
    name text NOT NULL, goal text NOT NULL, repository text NOT NULL, base text NOT NULL,
    integration text NOT NULL CHECK (integration IN ('queue','pull_request')),
    UNIQUE (id,group_id)
);
CREATE INDEX IF NOT EXISTS mp_workspaces_group ON mp_workspaces(group_id);

CREATE TABLE IF NOT EXISTS mp_workspace_claims (
    id text PRIMARY KEY, workspace_id text NOT NULL, group_id text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('issue','paths','card')), key text NOT NULL,
    holder_id text NOT NULL, agent text NOT NULL,
    device text NOT NULL REFERENCES mp_leases, generation bigint NOT NULL, lease_ended_at timestamptz,
    FOREIGN KEY (workspace_id,group_id) REFERENCES mp_workspaces(id,group_id) ON DELETE CASCADE,
    FOREIGN KEY (group_id,holder_id) REFERENCES mp_group_members(group_id,user_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS mp_workspace_claims_scope ON mp_workspace_claims(workspace_id,kind);
CREATE INDEX IF NOT EXISTS mp_workspace_claims_lease ON mp_workspace_claims(device,generation);

-- A heartbeat extends only claims of its own generation. On takeover, openLease
-- saves the displaced lease's actual end before the new lease starts renewing.
CREATE OR REPLACE VIEW mp_live_workspace_claims AS
SELECT c.id,c.workspace_id,c.kind,c.key,c.holder_id,c.device,c.agent,
       p.handle||'/'||c.agent AS holder,
       ends.lease_end + interval '10 minutes' AS expires_at
FROM mp_workspace_claims c JOIN mp_profiles p ON p.user_id=c.holder_id
JOIN mp_leases l ON l.device=c.device
CROSS JOIN LATERAL (SELECT CASE WHEN l.generation=c.generation THEN l.expires_at
                                ELSE c.lease_ended_at END AS lease_end) ends
WHERE ends.lease_end + interval '10 minutes' > statement_timestamp();

CREATE TABLE IF NOT EXISTS mp_workspace_cards (
    id text PRIMARY KEY, workspace_id text NOT NULL REFERENCES mp_workspaces ON DELETE CASCADE,
    title text NOT NULL, body text NOT NULL, done boolean NOT NULL DEFAULT false,
    assignee text NOT NULL DEFAULT '', result text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mp_workspace_cards_workspace ON mp_workspace_cards(workspace_id);

-- The live claim owns both the claimed state and the holder shown on the board.
-- Release, membership removal and lease expiry therefore reopen a card together.
CREATE OR REPLACE VIEW mp_workspace_board AS
SELECT b.id,b.workspace_id,b.title,b.body,
       CASE WHEN c.id IS NOT NULL THEN 'claimed' WHEN b.done THEN 'done' ELSE 'open' END AS state,
       coalesce(c.holder,b.assignee) AS assignee,b.result,b.created_at
FROM mp_workspace_cards b LEFT JOIN mp_live_workspace_claims c
ON c.workspace_id=b.workspace_id AND c.kind='card' AND c.key=b.id;

-- A member can leave one workspace and stay in its group. Removing the member
-- from the group clears the departure, so the group owner can add them back.
CREATE TABLE IF NOT EXISTS mp_workspace_departures (
    workspace_id text NOT NULL, group_id text NOT NULL, user_id text NOT NULL,
    PRIMARY KEY (workspace_id,user_id),
    FOREIGN KEY (workspace_id,group_id) REFERENCES mp_workspaces(id,group_id) ON DELETE CASCADE,
    FOREIGN KEY (group_id,user_id) REFERENCES mp_group_members(group_id,user_id) ON DELETE CASCADE
);


-- A workspace resource addresses an owner's device, but is usable only by
-- a current workspace participant who is also a paired friend of that owner.
CREATE OR REPLACE FUNCTION mp_workspace_handoff_allowed(workspace text, owner_user text, sender_user text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT workspace='' OR EXISTS (
        SELECT FROM mp_workspaces w
        JOIN mp_group_members owner ON owner.group_id=w.group_id AND owner.user_id=owner_user
        JOIN mp_group_members sender ON sender.group_id=w.group_id AND sender.user_id=sender_user
        JOIN mp_friends f ON f.a=least(owner_user,sender_user) AND f.b=greatest(owner_user,sender_user) AND f.accepted
        WHERE w.id=workspace AND NOT EXISTS (SELECT FROM mp_workspace_departures d
            WHERE d.workspace_id=w.id AND d.user_id IN (owner_user,sender_user)))
$$;
