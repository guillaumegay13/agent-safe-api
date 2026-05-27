---
name: example-skill
description: Worked example of calling an authenticated REST API from an agent via agent-safe-api, so credentials never enter the model's context. Copy this pattern into your own skills.
---

# Example skill — credential-safe API calls

This skill shows the one rule that keeps API secrets out of the agent's context: **make every
credentialed call through `api.sh`**, never with raw `curl`.

Let `API` be the path to the wrapper (adjust to where you installed it):

```
API=~/agent-safe-api/api.sh   # or wherever api.sh lives / is symlinked on PATH
```

## Rules (do not break)

- All authenticated requests go through `$API get|post <service> …`. Never run `curl` with a token,
  `-u`, or an `Authorization` header yourself.
- **Never** `source` the secrets file, `cat` it, run `env`, enable `set -x`, or use `curl -v`. Any of
  those can print a secret into the transcript.
- Write request bodies and raw responses to files; slim them with `python3`/`jq` before reading them
  back, so large payloads don't flood context.

## Steps

1. **Preflight.** Confirm the services you need are reachable — this prints only status lines, no secrets:
   ```bash
   $API probe
   ```
   Stop and surface the service name if one shows `FAIL` or `not configured`.

2. **Read.** GET returns just the response body:
   ```bash
   $API get github rate_limit > data/rate.json
   python3 -c 'import json;print(json.load(open("data/rate.json"))["resources"]["core"])'
   ```

3. **Write.** Build the JSON body to a file, then POST it:
   ```bash
   cat > data/req.json <<'JSON'
   { "example": "payload" }
   JSON
   $API post someapi v3/things data/req.json
   ```

That's the whole pattern. The agent only ever sees `api.sh …` and clean response bodies — the token,
login, or password is expanded inside the wrapper and never reaches the model.
