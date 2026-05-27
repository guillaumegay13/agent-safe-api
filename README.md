# agent-safe-api

Call authenticated REST APIs from an AI coding agent — **Claude Code, openclaw, Cursor, or any agent that
runs shell commands** — without leaking your API keys into the model's context.

## The problem

Coding agents send **both the command they run and its output** back to the model. And in most of them the
shell's environment **does not persist between tool calls**. So the obvious approach:

```bash
source .env
curl -H "Authorization: Bearer $TOKEN" https://api.example.com/v1/thing
```

leaks your token into the transcript the moment anything expands it — `set -x`, `curl -v`, an HTTP error
that echoes the request headers, or a later `env` / `cat .env`. Once a secret is in the context window it
can be logged, cached, or summarized into long-term memory. You can't un-send it.

## The fix

`api.sh` is a tiny wrapper the agent calls instead of `curl`. It:

- **sources your secrets internally** (on every call — because env doesn't persist) and references them
  only as `$VARS`, expanded at call time;
- runs `curl` with auth in `-u`/`-H`, **never in a URL, never with `-v`/`-x`**;
- for tokens minted by a command (e.g. a cloud CLI), captures the token via `$(...)` into a local var
  that is **never printed**;
- prints **only the response body**.

The agent only ever sees the subcommand it typed and a clean response:

```
$ api.sh get github rate_limit
{"resources":{ ... }}          # no token, anywhere
```

## Install

```bash
git clone https://github.com/guillaumegay13/agent-safe-api.git
chmod +x agent-safe-api/api.sh
# optional: put it on PATH
ln -s "$PWD/agent-safe-api/api.sh" ~/.local/bin/api.sh
```

Runs out of the box (the example config has a no-auth GitHub entry):

```bash
./api.sh probe
#   github         OK (HTTP 200)
./api.sh get github rate_limit
```

## Configure

**1. Declare your services** — copy `services.example.conf` to `services.conf` (next to `api.sh`, or at
`~/.config/agent-safe-api/services.conf`, or point `$AGENT_API_CONF` at it). Pipe-delimited:

```
name | base_url | auth | secret_spec | [test_method] | [test_path]
```

| `auth` | `secret_spec` | curl auth used |
|---|---|---|
| `bearer` | `TOKEN_ENVVAR` | `-H "Authorization: Bearer $TOKEN"` |
| `basic` | `LOGIN_ENVVAR:PASSWORD_ENVVAR` | `-u "$LOGIN:$PASSWORD"` |
| `token-cmd` | `ENVVAR_holding_a_command` | runs the command, uses its stdout as a bearer token |
| `none` | `-` | (no auth) |

**2. Put the secret values** in `~/.config/agent-safe-api/secrets.env` (copy from `secrets.env.example`,
then `chmod 600`). Override the path with `$AGENT_API_ENV`. For `token-cmd`, store the *command* that
prints a token, not a token — so it's always fresh and never sits on disk.

## Use

```bash
api.sh probe                          # check every configured service (safe output only)
api.sh services                       # list configured services
api.sh get  <service> <path>          # GET  <base_url>/<path>
api.sh post <service> <path> body.json   # POST a JSON body (file or "-" for stdin)
```

## Install the skill (optional)

This repo ships an agent skill at [`skills/agent-safe-api/SKILL.md`](skills/agent-safe-api/SKILL.md).
Installing it makes your agent reach for `api.sh` automatically whenever it needs to call an
authenticated API — no need to repeat the rules each session. For Claude Code (and compatible
agents that auto-discover `SKILL.md` skills):

```bash
cp -r agent-safe-api/skills/agent-safe-api ~/.claude/skills/
```

Or just hand the agent this repo's URL and ask it to install the skill. For agents that don't use
the `SKILL.md` format, the same rules work pasted into a system prompt or `AGENTS.md`.

The pattern is agent-agnostic: make **all** credentialed calls through `api.sh`, and never `source`
the env file, `cat` it, run `env`, `set -x`, or `curl -v`. It works the same whether the runner is
Claude Code, openclaw, Cursor, or anything else that executes shell.

## Hygiene guarantees (and their limits)

What `api.sh` guarantees: secrets don't reach **stdout, stderr, or the command the agent typed** —
the parts that flow into the model's context. It disables any inherited `xtrace` (`set +x`,
`unset BASH_XTRACEFD`) before touching a secret, and strips trace options for the token-command
subshell, so even an agent running with `SHELLOPTS=xtrace` can't trace a token into the transcript.

What it does **not** do:

- **It doesn't hide secrets from other local processes.** Auth goes in curl's `-u`/`-H` arguments,
  which are visible in `ps`/`/proc/<pid>/cmdline` to other processes on the same machine for the
  brief moment curl runs. That's outside the threat model (the agent never sees argv), but on a
  shared box it matters.
- **It prints response bodies verbatim.** If you GET a token-minting endpoint, or an API reflects
  your credential back in an (error) body, that lands in stdout → the agent. Don't point it at
  endpoints whose responses contain secrets.
- **It can't stop *you*** from writing a skill that runs `env` or `cat secrets.env` anyway — so keep
  those out of your skills, and keep `secrets.env` `chmod 600` and git-ignored.

Requires `bash` (3.2+, so stock macOS works) and `curl`.

## License

MIT — see [LICENSE](LICENSE).
