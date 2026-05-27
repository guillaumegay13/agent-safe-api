#!/usr/bin/env bash
# agent-safe-api — call authenticated REST APIs from an AI coding agent
# (Claude Code, openclaw, Cursor, …) WITHOUT leaking credentials into the
# model's context.
#
# WHY THIS EXISTS
#   Coding agents feed BOTH the command string AND its stdout/stderr back to the
#   model, and the shell's env vars usually don't persist between tool calls. So
#   a naive `curl -H "Authorization: Bearer $TOKEN" …` risks putting the secret
#   into the model context — via xtrace, `curl -v`, an error that echoes the
#   header, or a later `env`/`cat .env`. This wrapper sources secrets internally,
#   references them only as $VARS, and prints ONLY the response body. The agent
#   sees `api.sh get <service> <path>` and clean JSON — never a token.
#
# HYGIENE RULES (do not weaken):
#   - secrets are referenced only as $VARS, expanded at call time; never echoed,
#     never written to a URL.
#   - no `set -x`; curl is never run with -v/--trace.
#   - token-command output is captured via $(...) into a local var, never printed.
#   - the env file is sourced on EVERY call (env doesn't persist across agent
#     tool calls), so the agent never runs `source`, `cat .env`, or `env`.
#
# USAGE
#   api.sh probe                         # check every configured service (safe output)
#   api.sh get  <service> <path>         # GET  <base>/<path>
#   api.sh post <service> <path> [body]  # POST; body = file path or "-" for stdin
#   api.sh services                      # list configured service names
#
# CONFIG  (services.conf, pipe-delimited; '#' comments; see services.example.conf)
#   name | base_url | auth | secret_spec | [test_method] | [test_path]
#     auth=bearer     secret_spec = TOKEN_ENVVAR
#     auth=basic      secret_spec = LOGIN_ENVVAR:PASSWORD_ENVVAR
#     auth=token-cmd  secret_spec = ENVVAR_HOLDING_A_COMMAND_THAT_PRINTS_A_TOKEN
#     auth=none       secret_spec = -
#   Lookup order: $AGENT_API_CONF, ./services.conf next to this script,
#   ~/.config/agent-safe-api/services.conf, then services.example.conf (demo).
#
# SECRETS  loaded from $AGENT_API_ENV (default ~/.config/agent-safe-api/secrets.env),
#   sourced on every call. `chmod 600` it; never commit it.
set +x                 # disable any xtrace inherited via SHELLOPTS/BASH_XTRACEFD before
unset -v BASH_XTRACEFD 2>/dev/null || true   # touching secrets — xtrace would echo them to stderr
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AGENT_API_ENV:-$HOME/.config/agent-safe-api/secrets.env}"

# Resolve config file
CONF="${AGENT_API_CONF:-}"
if [ -z "$CONF" ]; then
  for c in "$HERE/services.conf" "$HOME/.config/agent-safe-api/services.conf" "$HERE/services.example.conf"; do
    [ -f "$c" ] && { CONF="$c"; break; }
  done
fi
[ -n "$CONF" ] && [ -f "$CONF" ] || { echo "api.sh: no services config found (set \$AGENT_API_CONF)" >&2; exit 2; }

# Load secrets quietly. File optional; vars may already be exported.
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE" >/dev/null 2>&1; set +a; }

die(){ echo "api.sh: $*" >&2; exit 2; }
body_in(){ if [ "$1" = "-" ]; then cat; else cat -- "$1"; fi; }
trim(){ printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# Find a service row; sets F_NAME F_BASE F_AUTH F_SPEC F_TM F_TP
find_service(){
  local svc="$1" line
  line="$(grep -E "^[[:space:]]*${svc}[[:space:]]*\|" "$CONF" | head -1 || true)"
  [ -n "$line" ] || die "unknown service: $svc (not in $CONF)"
  local a b c d e f; IFS='|' read -r a b c d e f <<<"$line"
  F_NAME="$(trim "$a")"; F_BASE="$(trim "$b")"; F_AUTH="$(trim "$c")"
  F_SPEC="$(trim "$d")"; F_TM="$(trim "${e:-GET}")"; F_TP="$(trim "${f:-}")"
}

# Build curl auth args into AUTH_ARGS (values are secrets — never printed)
auth_args(){
  AUTH_ARGS=()
  case "$1" in
    none|-) ;;
    bearer)    local v="$2"; [ -n "${!v:-}" ] || die "missing env var: $v";
               AUTH_ARGS=(-H "Authorization: Bearer ${!v}");;
    basic)     local lv="${2%%:*}" pv="${2##*:}";
               { [ -n "${!lv:-}" ] && [ -n "${!pv:-}" ]; } || die "missing env var(s): $2";
               AUTH_ARGS=(-u "${!lv}:${!pv}");;
    token-cmd) local cv="$2"; [ -n "${!cv:-}" ] || die "missing env var: $cv";
               # strip xtrace opts for the child so a traced token command can't echo the token
               local tok; tok="$(env -u SHELLOPTS -u BASH_XTRACEFD bash -c "${!cv}")"; [ -n "$tok" ] || die "token command produced no token";
               AUTH_ARGS=(-H "Authorization: Bearer ${tok}");;
    *) die "unknown auth type: $1";;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  get)
    find_service "${1:?service}"; auth_args "$F_AUTH" "$F_SPEC"
    out="$(mktemp)"; trap 'rm -f "$out"' EXIT
    # ${AUTH_ARGS[@]+...} form so an empty array doesn't trip `set -u` on bash 3.2 (macOS)
    code="$(curl -sS -o "$out" -w '%{http_code}' ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$F_BASE/${2#/}")" || { cat "$out"; exit 1; }
    cat "$out"
    [ "${code:0:1}" = "2" ] || { echo "api.sh: HTTP $code from $F_NAME/${2#/}" >&2; exit 1; }
    ;;
  post)
    find_service "${1:?service}"; auth_args "$F_AUTH" "$F_SPEC"
    out="$(mktemp)"; trap 'rm -f "$out"' EXIT
    code="$(body_in "${3:--}" | curl -sS -o "$out" -w '%{http_code}' ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -H 'Content-Type: application/json' --data-binary @- "$F_BASE/${2#/}")" || { cat "$out"; exit 1; }
    cat "$out"
    [ "${code:0:1}" = "2" ] || { echo "api.sh: HTTP $code from $F_NAME/${2#/}" >&2; exit 1; }
    ;;
  services)
    grep -vE '^[[:space:]]*(#|$)' "$CONF" | while IFS='|' read -r n b a s _; do printf '%s\t(%s, %s)\n' "$(trim "$n")" "$(trim "$b")" "$(trim "$a")"; done
    ;;
  probe)
    set +e +o pipefail
    echo "agent-safe-api probe (config: $CONF) — no secrets are printed:"
    grep -vE '^[[:space:]]*(#|$)' "$CONF" | while IFS='|' read -r n b a s tm tp; do
      n="$(trim "$n")"; b="$(trim "$b")"; a="$(trim "$a")"; s="$(trim "$s")"; tp="$(trim "${tp:-}")"
      ok=1
      case "$a" in
        bearer|token-cmd) [ -n "${!s:-}" ] || ok=0;;
        basic) lv="${s%%:*}"; pv="${s##*:}"; { [ -n "${!lv:-}" ] && [ -n "${!pv:-}" ]; } || ok=0;;
      esac
      if [ "$ok" = 0 ]; then printf '  %-14s not configured\n' "$n"; continue; fi
      if [ -n "$tp" ]; then
        auth_args "$a" "$s" 2>/dev/null
        code="$(curl -sS -o /dev/null -w '%{http_code}' ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$b/${tp#/}" 2>/dev/null)"
        [ "${code:0:1}" = "2" ] && printf '  %-14s OK (HTTP %s)\n' "$n" "$code" || printf '  %-14s FAIL (HTTP %s)\n' "$n" "$code"
      else printf '  %-14s configured (no test path)\n' "$n"; fi
    done
    ;;
  ""|-h|--help|help) sed -n '2,46p' "$HERE/api.sh" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $cmd (try: api.sh help)";;
esac
