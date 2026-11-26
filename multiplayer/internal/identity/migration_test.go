package identity

import "testing"

func TestBackfillMembersFromDeviceEnrollments(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	_, err := pool.Exec(ctx, `CREATE TABLE mp_auth_devices(
		device text PRIMARY KEY, user_id text NOT NULL, encryption_key text NOT NULL, descriptor jsonb NOT NULL,
		access_hash bytea, access_expires timestamptz, refresh_hash bytea, refresh_expires timestamptz,
		revoked boolean NOT NULL DEFAULT false, email_hash text)`)
	if err != nil {
		t.Fatal(err)
	}
	newKey := emailHash("Sam@Example.test")
	_, err = pool.Exec(ctx, `INSERT INTO mp_auth_devices(device,user_id,encryption_key,descriptor,access_expires,email_hash) VALUES
		('first','sam','one','{}',now()-interval '1 day',$1), ('second','sam','two','{}',now(),$2),
		('third','sam','three','{}',now()+interval '1 day',''), ('fourth','no-email','four','{}',NULL,NULL)`,
		emailHash("previous@example.test"), newKey)
	if err != nil {
		t.Fatal(err)
	}
	f := issuer(t, "")
	cfg := Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true}
	if _, err := New(ctx, pool, cfg); err != nil {
		t.Fatal(err)
	}
	var key, unknown string
	var members, joins int
	err = pool.QueryRow(ctx, `SELECT (SELECT contact_key FROM mp_members WHERE user_id='sam'),
		(SELECT contact_key FROM mp_members WHERE user_id='no-email'), (SELECT count(*) FROM mp_members),
		(SELECT count(*) FROM mp_events)`).Scan(&key, &unknown, &members, &joins)
	if err != nil || key != newKey || unknown != "" || members != 2 || joins != 0 {
		t.Fatalf("backfill returned key %q, unknown %q, %d members, %d events: %v", key, unknown, members, joins, err)
	}
}
