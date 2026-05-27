---
name: agent-safe-api
description: Use whenever you need to call an authenticated or credentialed REST API from the shell — any service that needs an API key, Bearer token, basic auth, or a CLI-minted token. Routes every credentialed request through the api.sh wrapper so the secret never enters the model's context (no tokens in commands, transcripts, or logs).
---

# agent-safe-api — credential-safe API calls

When you call an authenticated API from the shell, the agent sends **both the command and its
output** back to the model, and env vars usually don't persist between tool calls. So a naive
`curl -H "Authorization: Bearer $TOKEN" …` leaks the token into the transcript the moment anything
expands it. This skill keeps every credentialed call going through `api.sh`, which sources secrets
internally and prints **only the response body** — the token never reaches the model.

## Locate the wrapper

Set `API` to wherever `api.sh` lives, and verify it before using it:

```bash
API="$(command -v api.sh || echo ~/agent-safe-api/api.sh)"   # adjust if cloned elsewhere
[ -x "$API" ] || echo "api.sh not found — clone https://github.com/guillaumegay13/agent-safe-api and chmod +x api.sh"
```

If it isn't installed, tell the user to `git clone https://github.com/guillaumegay13/agent-safe-api`,
`chmod +x api.sh`, and configure `services.conf` + `secrets.env` per that repo's README. Don't work
around a missing wrapper by calling `curl` with credentials yourself.

## Rules (do not break)

- **All** authenticated requests go through `$API get|post <service> …`. Never run `curl` with a
  token, `-u`, or an `Authorization` header yourself, and never put a secret in a URL.
- **Never** `source` the secrets file, `cat` it, run `env`, enable `set -x`, or pass `curl -v`/`--trace`.
  Any of those can print a secret into the transcript. The wrapper sources secrets on every call so
  you never have to.
- Write request bodies and raw responses to files; slim them with `jq`/`python3` before reading them
  back, so large payloads don't flood context.

## Steps

1. **Preflight.** Confirm the services you need are reachable. This prints only status lines, no secrets:
   ```bash
   $API probe       # or: $API services   to list configured service names
   ```
   Stop and surface the service name if one shows `FAIL` or `not configured`.

2. **Read (GET).** Returns just the response body:
   ```bash
   $API get github rate_limit > data/rate.json
   jq '.resources.core' data/rate.json
   ```

3. **Write (POST).** Build the JSON body to a file (or pipe via `-`), then POST it:
   ```bash
   cat > data/req.json <<'JSON'
   { "example": "payload" }
   JSON
   $API post someapi v3/things data/req.json
   ```

That's the whole pattern. You only ever see `api.sh …` and clean response bodies — the token, login,
or password is expanded inside the wrapper and never reaches the model.
