# Deploying `main` over Tailscale

The `deploy` job in `.github/workflows/validate.yml` runs only after the full
validation job succeeds for a push to `main`. It joins the tailnet as an
ephemeral `tag:ci` node and sends an HMAC-authenticated request to the existing
update receiver through `home.taila70923.ts.net`.

The daily `nixos-update.timer` remains enabled as a fallback if a workflow run
or delivery is missed.

## One-time Tailscale setup

1. In the Tailscale admin console, create an OAuth client with the writable
   `auth_keys` scope and permission to create nodes carrying `tag:ci`.
2. Ensure the tailnet policy allows `tag:ci` to reach TCP port 80 on the
   `home` node. Do not grant the CI tag broader access than required.
3. Add the OAuth credentials as GitHub Actions repository secrets:
   - `TS_OAUTH_CLIENT_ID`
   - `TS_OAUTH_SECRET`

The action creates pre-approved ephemeral nodes and removes them after each
workflow run.

## One-time HMAC setup

The receiver reads its secret from:

```text
/var/lib/hermes/.hermes/secrets/github-webhook-secret
```

Store the exact same value as the GitHub Actions repository secret
`NIXOS_DEPLOY_WEBHOOK_SECRET`. Do not commit or print the value. The receiver
rejects requests with a missing or invalid HMAC, non-push events, and refs other
than `refs/heads/main`.

The endpoint uses HTTP only inside the encrypted tailnet. It is not exposed by
opening a new firewall port; nginx forwards `/webhook/` to the loopback-only
receiver.

## Verification

After merging this workflow change and configuring the three repository
secrets, inspect the `Validate NixOS configuration` workflow for a push to
`main`:

1. `Tests and system build` must complete successfully.
2. `Join the tailnet` must ping `home.taila70923.ts.net`.
3. `Trigger the authenticated update receiver` must return
   `nixos-update queued`.
4. On the server, verify `nixos-update.service` completed successfully and the
   active system generation contains the merged commit.
