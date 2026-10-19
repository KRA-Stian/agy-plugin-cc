#!/usr/bin/env bash
# agy-run.sh: Claude Code wrapper around the Google Antigravity CLI (`agy`).
#
# Every agy call runs as a job: a directory under $AGY_PLUGIN_HOME/jobs that
# holds the prompt, agy's raw output and log, and the final result. agy is
# started detached, so a Claude Code Bash timeout or interrupt never kills a
# running agent; foreground commands wait for the job and print its result,
# --background returns the job id straight away.
#
# Portable to bash 3.2 (macOS): no associative arrays, ${x,,} or mapfile, and
# arrays that may be empty are expanded as ${a[@]+"${a[@]}"}.

set -u -o pipefail

AGY_PLUGIN_VERSION="1.0.0"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
AGY_HOME="${AGY_HOME:-$HOME/.gemini/antigravity-cli}"
STATE_DIR="${AGY_PLUGIN_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/agy-plugin}"
JOBS_DIR="$STATE_DIR/jobs"
WAIT_DEFAULT="${AGY_WAIT_SECONDS:-540}"
POLL_INTERVAL="${AGY_POLL_INTERVAL:-1}"
MAX_ARG_BYTES="${AGY_MAX_ARG_BYTES:-100000}"
RETENTION_DAYS="${AGY_JOB_RETENTION_DAYS:-7}"
IMAGE_GRACE="${AGY_IMAGE_GRACE_SECONDS:-30}"
INSTALL_HINT="curl -fsSL https://antigravity.google/cli/install.sh | bash"
# How hints refer to this script: bin/agy-run sets AGY_RUN_CMD=agy-run.
RUN_CMD="${AGY_RUN_CMD:-bash \"$SCRIPT_PATH\"}"

EX_FAIL=1
EX_NOOUTPUT=3
EX_NOIMAGE=4
EX_USAGE=64
EX_RUNNING=75
EX_NOAGY=127
EX_CANCELLED=130

# ---------------------------------------------------------------- helpers ---

note() { printf '[agy] %s\n' "$*" >&2; }
die() { local code="$1"; shift; printf 'error: %s\n' "$*" >&2; exit "$code"; }
usage_error() { die "$EX_USAGE" "$@"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
now() { date +%s; }
cap() { printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"; }
byte_len() { printf '%s' "$1" | wc -c | tr -d ' '; }
one_line() { printf '%s' "$1" | tr '\n\r\t' '   '; }
fmt_secs() { awk -v s="$1" 'BEGIN { printf "%.1f", s + 0 }'; }

# JSON string escaping for the small objects this script prints itself.
j_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

abspath() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}

# run_with_timeout <seconds> <cmd...>: portable stand-in for timeout(1).
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$secs" ]; do sleep 1; n=$((n + 1)); done
    kill -TERM "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

find_agy() {
  if [ -n "${AGY_BIN:-}" ]; then
    [ -x "$AGY_BIN" ] && { printf '%s\n' "$AGY_BIN"; return 0; }
    return 1
  fi
  local p
  p="$(command -v agy 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
  for p in "$HOME/.local/bin/agy" "/opt/antigravity/bin/agy" "/usr/local/bin/agy"; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

require_agy() {
  AGY="$(find_agy)" || die "$EX_NOAGY" "agy (Google Antigravity CLI) is not installed or not on PATH.
       Install it with:  $INSTALL_HINT
       then run /agy:setup (or point AGY_BIN at the agy binary)."
}

JSON_HELPER=""
detect_json_helper() {
  [ -n "$JSON_HELPER" ] && return 0
  case "${AGY_PLUGIN_JSON:-auto}" in
    python3 | node | none) JSON_HELPER="$AGY_PLUGIN_JSON" ;;
    *)
      if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
        JSON_HELPER=python3
      elif command -v node >/dev/null 2>&1 && node -e '' >/dev/null 2>&1; then
        JSON_HELPER=node
      else
        JSON_HELPER=none
      fi ;;
  esac
}

default_model() {
  [ -f "$AGY_HOME/settings.json" ] || return 1
  grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$AGY_HOME/settings.json" 2>/dev/null \
    | head -n 1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
}

# ----------------------------------------------------------------- models ---
# The lineup agy offers today. Each family has Low / Medium / High thinking
# levels (GPT-OSS only Medium); a bare alias means the family's default level.

family_display() {
  case "$1" in
    flash) echo "Gemini 3.8 Flash" ;;
    argon) echo "Gemini 4 Argon" ;;
    opus) echo "Claude Opus 5.5" ;;
    sonnet) echo "Claude Sonnet 5.5" ;;
    gpt-oss) echo "GPT-OSS 120B" ;;
  esac
}

# Base model ids; agy combines these with --effort for levels outside the table.
family_base_id() {
  case "$1" in
    flash) echo "gemini-3.8-flash" ;;
    argon) echo "gemini-4-argon" ;;
    opus) echo "claude-opus-5-5" ;;
    sonnet) echo "claude-sonnet-5-5" ;;
    gpt-oss) echo "gpt-oss-120b" ;;
  esac
}

family_levels() {
  case "$1" in
    gpt-oss) echo "medium" ;;
    *) echo "low medium high" ;;
  esac
}

family_default_level() {
  case "$1" in
    flash) echo high ;;
    *) echo medium ;;
  esac
}

# Regex (ERE) matching a family's display names in `agy models`, used to find
# a newer model when a built-in alias stops being offered.
family_pattern() {
  case "$1" in
    flash) echo '^Gemini [0-9.]+ Flash \(' ;;
    argon) echo '^Gemini [0-9.]+ Argon \(' ;;
    opus) echo '^Claude Opus [0-9.]+ \(' ;;
    sonnet) echo '^Claude Sonnet [0-9.]+ \(' ;;
    gpt-oss) echo '^GPT-OSS ' ;;
  esac
}

norm_level() {
  case "$(lower "$1")" in
    low) echo low ;;
    med | medium) echo medium ;;
    high) echo high ;;
    xhigh) echo xhigh ;;
    max) echo max ;;
    *) return 1 ;;
  esac
}

# parse_model <name>: recognise aliases ("opus-high"), display names
# ("Claude Opus 5.5 (High)") and model ids ("claude-opus-5-5-high").
# Sets M_FAMILY and M_LEVEL (level may be empty); returns 1 for other names.
parse_model() {
  M_FAMILY=""
  M_LEVEL=""
  local lc name lvl=""
  lc="$(lower "$1")"
  case "$lc" in
    *" ("*")")
      case "${lc% (*}" in
        "gemini 3.8 flash") M_FAMILY=flash ;;
        "gemini 4 argon") M_FAMILY=argon ;;
        "claude opus 5.5") M_FAMILY=opus ;;
        "claude sonnet 5.5") M_FAMILY=sonnet ;;
        "gpt-oss 120b") M_FAMILY=gpt-oss ;;
        *) return 1 ;;
      esac
      lvl="${lc##* (}"
      M_LEVEL="$(norm_level "${lvl%)}")" || { M_FAMILY=""; return 1; }
      return 0 ;;
  esac
  name="$lc"
  case "$lc" in
    *-low | *-med | *-medium | *-high | *-xhigh | *-max)
      lvl="${lc##*-}"
      name="${lc%-*}" ;;
  esac
  case "$name" in
    flash | gemini-flash | gemini-3.8-flash) M_FAMILY=flash ;;
    argon | gemini-argon | gemini-4-argon) M_FAMILY=argon ;;
    opus | claude-opus | claude-opus-5-5 | claude-opus-5.5) M_FAMILY=opus ;;
    sonnet | claude-sonnet | claude-sonnet-5-5 | claude-sonnet-5.5) M_FAMILY=sonnet ;;
    gpt-oss | gpt-oss-120b) M_FAMILY=gpt-oss ;;
    *) return 1 ;;
  esac
  [ -n "$lvl" ] && M_LEVEL="$(norm_level "$lvl")"
  return 0
}

model_error() {
  printf 'error: %s\n\n' "$*" >&2
  print_model_table >&2
  exit "$EX_USAGE"
}

# resolve_model <model> <effort>: sets R_MODEL / R_EFFORT (the values passed
# to agy's --model / --effort, either may be empty) and R_FAMILY / R_LEVEL for
# names this plugin knows.
resolve_model() {
  local in="$1" eff_in="$2" eff="" lvl
  R_MODEL=""
  R_EFFORT=""
  R_FAMILY=""
  R_LEVEL=""
  if [ -n "$eff_in" ]; then
    eff="$(norm_level "$eff_in")" || usage_error "invalid thinking level '$eff_in' (use low, medium, high, xhigh or max)"
  fi
  if [ -z "$in" ]; then
    R_EFFORT="$eff" # agy applies it to the default model
    return 0
  fi
  case "$(lower "$in")" in
    pro | pro-* | gemini-pro | gemini-pro-*)
      model_error "'$in': Gemini 3.1 Pro is no longer in agy's lineup. Use argon (Gemini 4 Argon), e.g. --model argon-high." ;;
  esac
  if ! parse_model "$in"; then
    # Not in the table: let agy validate it, so new models work right away.
    R_MODEL="$in"
    R_EFFORT="$eff"
    return 0
  fi
  lvl="$M_LEVEL"
  if [ -n "$eff" ]; then
    if [ -n "$lvl" ] && [ "$lvl" != "$eff" ]; then
      usage_error "--model $in conflicts with --effort $eff_in; give the thinking level once (e.g. --model $M_FAMILY --effort $eff)."
    fi
    lvl="$eff"
  fi
  [ -n "$lvl" ] || lvl="$(family_default_level "$M_FAMILY")"
  R_FAMILY="$M_FAMILY"
  R_LEVEL="$lvl"
  case " $(family_levels "$M_FAMILY") " in
    *" $lvl "*) R_MODEL="$(family_display "$M_FAMILY") ($(cap "$lvl"))" ;;
    *)
      # A level the table doesn't list: hand agy the base id plus --effort and
      # let it decide whether the model offers that level.
      R_MODEL="$(family_base_id "$M_FAMILY")"
      R_EFFORT="$lvl" ;;
  esac
}

print_model_table() {
  cat <<'TABLE'
Models (aliases are case-insensitive; thinking level = low | medium | high):
  flash    flash-low   flash-medium   flash-high     Gemini 3.8 Flash    (flash = High)
  argon    argon-low   argon-medium   argon-high     Gemini 4 Argon      (argon = Medium)
  opus     opus-low    opus-medium    opus-high      Claude Opus 5.5     (opus = Medium)
  sonnet   sonnet-low  sonnet-medium  sonnet-high    Claude Sonnet 5.5   (sonnet = Medium)
  gpt-oss                                            GPT-OSS 120B        (Medium only)

  --effort LEVEL (alias --thinking) picks the level for a bare alias:
  "--model opus --effort high" is the same as "--model opus-high".
  Also accepted: display names ("Claude Opus 5.5 (High)"), model ids
  ("claude-opus-5-5-high"), claude-opus / claude-sonnet / gpt-oss-120b and
  -med for -medium. Any other name goes to agy unchanged, so models added to
  agy later work before this table is updated (see `agy models`).
  Without --model, agy uses the default model picked in its TUI.
TABLE
}

# find_successor <family> <level>: newest model of that family and level that
# `agy models` lists (used when a built-in alias is no longer offered).
find_successor() {
  local fam="$1" lvl="$2" pat out
  pat="$(family_pattern "$fam")"
  out="$(run_with_timeout 30 "$AGY" models </dev/null 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -F '\t' -v pat="$pat" -v lvl="($(cap "$lvl"))" '
    NF >= 2 && $2 ~ pat && index($2, lvl) == length($2) - length(lvl) + 1 {
      key = ""
      n = split($2, words, " ")
      for (i = 1; i <= n; i++) if (words[i] ~ /^[0-9]+(\.[0-9]+)*$/) {
        m = split(words[i], parts, ".")
        for (j = 1; j <= 4; j++) key = key sprintf("%06d", (j <= m ? parts[j] : 0))
        break
      }
      print key "\t" $2
    }' | sort -r | head -n 1 | cut -f 2-
}

# ------------------------------------------------------------- job store ---

meta_set() { printf '%s=%s\n' "$2" "$(one_line "$3")" >>"$1/meta"; }
meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | tail -n 1; }

job_done() { [ -f "$1/exit_code" ]; }

job_alive() {
  local pid
  pid="$(cat "$1/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

job_state() {
  local created
  if job_done "$1"; then
    meta_get "$1" state
  elif job_alive "$1"; then
    echo running
  elif [ -f "$1/pid" ]; then
    echo lost
  else
    # The runner writes its pid as it starts; give it a moment.
    created="$(meta_get "$1" created)"
    if [ $(($(now) - ${created:-0})) -lt 15 ]; then echo starting; else echo lost; fi
  fi
}

prune_jobs() {
  local days="$1" cutoff jd fin
  [ -d "$JOBS_DIR" ] || return 0
  cutoff=$(($(now) - days * 86400))
  for jd in "$JOBS_DIR"/*/; do
    jd="${jd%/}"
    [ -d "$jd" ] && job_done "$jd" || continue
    fin="$(meta_get "$jd" finished)"
    [ -n "$fin" ] && [ "$fin" -lt "$cutoff" ] && rm -rf "$jd"
  done
  return 0
}

create_job() {
  local kind="$1" base id n=0
  mkdir -p "$JOBS_DIR" || die "$EX_FAIL" "cannot create $JOBS_DIR"
  prune_jobs "$RETENTION_DAYS"
  base="$(date +%Y%m%d-%H%M%S)"
  while :; do
    id="$base-$(printf '%04x' $((RANDOM % 65536)))"
    mkdir "$JOBS_DIR/$id" 2>/dev/null && break
    n=$((n + 1))
    [ "$n" -lt 50 ] || die "$EX_FAIL" "cannot allocate a job id in $JOBS_DIR"
  done
  JOB_ID="$id"
  JD="$JOBS_DIR/$id"
  : >"$JD/meta"
  meta_set "$JD" id "$id"
  meta_set "$JD" kind "$kind"
  meta_set "$JD" created "$(now)"
}

latest_job() {
  [ -d "$JOBS_DIR" ] || return 1
  local last
  last="$(ls -1 "$JOBS_DIR" 2>/dev/null | sort | tail -n 1)"
  [ -n "$last" ] && printf '%s\n' "$last"
}

# resolve_job <id|prefix|last>: sets JD and JOB_ID or exits with an error.
resolve_job() {
  local ref="${1:-last}" matches count
  if [ "$ref" = last ]; then
    ref="$(latest_job)" || die "$EX_FAIL" "no agy jobs yet (state dir: $STATE_DIR)"
  fi
  case "$ref" in
    "" | *[!A-Za-z0-9_-]*) die "$EX_USAGE" "invalid job id '$ref'" ;;
  esac
  if [ ! -d "$JOBS_DIR/$ref" ]; then
    matches=""
    count=0
    for id in $(ls -1 "$JOBS_DIR" 2>/dev/null); do
      case "$id" in "$ref"*) matches="$id"; count=$((count + 1)) ;; esac
    done
    [ "$count" = 1 ] || die "$EX_FAIL" "no unique agy job matches '$ref' (see: status)"
    ref="$matches"
  fi
  JOB_ID="$ref"
  JD="$JOBS_DIR/$ref"
}

launch_job() {
  local log="$JD/runner.log"
  if command -v setsid >/dev/null 2>&1; then
    meta_set "$JD" detach setsid
    setsid "$BASH" "$SCRIPT_PATH" _job-run "$JD" </dev/null >>"$log" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    meta_set "$JD" detach perl
    perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die "exec: $!\n"' \
      "$BASH" "$SCRIPT_PATH" _job-run "$JD" </dev/null >>"$log" 2>&1 &
  else
    meta_set "$JD" detach nohup
    nohup "$BASH" "$SCRIPT_PATH" _job-run "$JD" </dev/null >>"$log" 2>&1 &
  fi
}

# wait_job <dir> <seconds, 0 = no limit>: 0 when finished, 75 when still
# running at the deadline, 1 when the runner died without recording a result.
wait_job() {
  local jd="$1" secs="$2" start state
  start="$(now)"
  while :; do
    job_done "$jd" && return 0
    state="$(job_state "$jd")"
    if [ "$state" = lost ]; then
      sleep 1
      job_done "$jd" && return 0
      return 1
    fi
    if [ "$secs" -gt 0 ] && [ $(($(now) - start)) -ge "$secs" ]; then
      return "$EX_RUNNING"
    fi
    sleep "$POLL_INTERVAL"
  done
}

meta_line() {
  local jd="$1" parts label cid dur tok
  label="$(meta_get "$jd" model_label)"
  [ -n "$label" ] || label="$(meta_get "$jd" model)"
  cid="$(meta_get "$jd" conversation)"
  dur="$(meta_get "$jd" duration)"
  tok="$(meta_get "$jd" tokens)"
  parts="job=$(meta_get "$jd" id)"
  [ -n "$label" ] && parts="$parts model=\"$label\""
  [ -n "$cid" ] && parts="$parts conversation=$cid"
  [ -n "$dur" ] && parts="$parts time=${dur}s"
  [ -n "$tok" ] && parts="$parts tokens=$tok"
  note "$parts"
}

still_running_message() {
  local id="$1" waited="$2"
  printf 'agy job %s is still running%s; it keeps going in the background.\n' "$id" "$waited"
  printf 'Wait for it:  %s wait %s\n' "$RUN_CMD" "$id"
  printf 'Check on it:  %s status %s\n' "$RUN_CMD" "$id"
  printf 'Stop it:      %s cancel %s\n' "$RUN_CMD" "$id"
}

# print_result <dir>: show a finished job's result and return its exit code.
print_result() {
  local jd="$1" code
  code="$(cat "$jd/exit_code" 2>/dev/null)"
  [ -n "$code" ] || code="$EX_FAIL"
  if [ -s "$jd/result.txt" ]; then
    cat "$jd/result.txt"
  fi
  if [ -s "$jd/notes.txt" ]; then
    while IFS= read -r line; do note "$line"; done <"$jd/notes.txt"
  fi
  if [ "$code" != 0 ] && [ -s "$jd/error.txt" ]; then
    cat "$jd/error.txt" >&2
  fi
  meta_line "$jd"
  return "$code"
}

show_finished_or_wait() {
  local jd="$1" secs="$2" rc
  wait_job "$jd" "$secs"
  rc=$?
  case "$rc" in
    0) print_result "$jd"; return $? ;;
    "$EX_RUNNING")
      still_running_message "$(meta_get "$jd" id)" " after ${secs}s"
      return "$EX_RUNNING" ;;
    *)
      printf 'error: agy job %s stopped without recording a result (runner log: %s)\n' \
        "$(meta_get "$jd" id)" "$jd/runner.log" >&2
      tail -n 5 "$jd/runner.log" >&2 2>/dev/null
      return "$EX_FAIL" ;;
  esac
}

# ------------------------------------------------------------ job runner ---
# `_job-run <dir>` runs detached: it calls agy (retrying once with a newer
# model if a built-in alias is no longer offered, and once to recover a run
# that a denied permission cut short), then writes result.txt / error.txt
# and finally exit_code, which marks the job as finished.

PY_PARSE='
import json, sys
src, resp = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()
data = None
try:
    data = json.loads(text)
except Exception:
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                data = json.loads(line)
                break
            except Exception:
                pass
if not isinstance(data, dict):
    sys.exit(3)
with open(resp, "w", encoding="utf-8") as f:
    f.write(data.get("response") or "")
usage = data.get("usage") or {}
def c(v):
    return "" if v is None else " ".join(str(v).split())
print("status=" + c(data.get("status")))
print("conversation_id=" + c(data.get("conversation_id")))
print("error=" + c(data.get("error"))[:4000])
print("duration=" + c(data.get("duration_seconds")))
print("tokens=" + c(usage.get("total_tokens")))
'

JS_PARSE='
const fs = require("fs");
const [src, resp] = process.argv.slice(1);
const text = fs.readFileSync(src, "utf8");
let d = null;
try { d = JSON.parse(text); } catch (e) {
  for (const l of text.split(/\r?\n/).reverse()) {
    const t = l.trim();
    if (t.startsWith("{")) { try { d = JSON.parse(t); break; } catch (e2) {} }
  }
}
if (!d || typeof d !== "object") process.exit(3);
fs.writeFileSync(resp, d.response || "");
const c = (v) => (v === undefined || v === null ? "" : String(v).split(/\s+/).filter(Boolean).join(" "));
const u = d.usage || {};
process.stdout.write([
  "status=" + c(d.status), "conversation_id=" + c(d.conversation_id),
  "error=" + c(d.error).slice(0, 4000), "duration=" + c(d.duration_seconds),
  "tokens=" + c(u.total_tokens)].join("\n") + "\n");
'

kv_get() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

RECOVERY_PROMPT='[Notice from the Claude Code wrapper] Your previous step needed a permission that this headless session cannot grant (for example a shell command), so it was auto-denied and the run stopped before you replied. Do not retry it and do not run shell commands. Reply now with your final answer. If you changed any files, list them, say what is left undone, and give the exact commands someone should run to verify the work.'

# attempt <tag> <prompt> [extra agy args...]: one agy call. Sets A_RC,
# A_STATUS, A_CID, A_ERROR, A_DURATION, A_TOKENS; response in $JD/<tag>.response.
attempt() {
  local tag="$1" prompt="$2" fmt=json kv t0
  shift 2
  [ "$JSON_HELPER" = none ] && fmt=text
  t0="$(now)"
  "$AGY" -p "$prompt" ${BASE_ARGS[@]+"${BASE_ARGS[@]}"} "$@" --output-format "$fmt" \
    --log-file "$JD/$tag.log" </dev/null >"$JD/$tag.out" 2>"$JD/$tag.err" &
  AGY_PID=$!
  printf '%s\n' "$AGY_PID" >"$JD/agy.pid"
  wait "$AGY_PID"
  A_RC=$?
  AGY_PID=""
  rm -f "$JD/agy.pid"
  A_STATUS=""
  A_CID=""
  A_ERROR=""
  A_DURATION=""
  A_TOKENS=""
  : >"$JD/$tag.response"
  if [ "$fmt" = json ]; then
    local prc=1
    kv=""
    case "$JSON_HELPER" in
      python3) kv="$(PYTHONIOENCODING=utf-8 python3 -I -c "$PY_PARSE" "$JD/$tag.out" "$JD/$tag.response" 2>/dev/null)" && prc=0 ;;
      node) kv="$(node -e "$JS_PARSE" "$JD/$tag.out" "$JD/$tag.response" 2>/dev/null)" && prc=0 ;;
    esac
    if [ "$prc" -eq 0 ] && [ -n "$kv" ]; then
      A_STATUS="$(kv_get "$kv" status)"
      A_CID="$(kv_get "$kv" conversation_id)"
      A_ERROR="$(kv_get "$kv" error)"
      A_DURATION="$(kv_get "$kv" duration)"
      A_TOKENS="$(kv_get "$kv" tokens)"
    elif [ "$A_RC" -eq 0 ]; then
      cp "$JD/$tag.out" "$JD/$tag.response" # not JSON after all: keep it as text
    fi
  else
    cp "$JD/$tag.out" "$JD/$tag.response"
  fi
  if [ -z "$A_CID" ] && [ -f "$JD/$tag.log" ]; then
    A_CID="$(grep -o 'conversation=[0-9a-fA-F-]\{36\}' "$JD/$tag.log" 2>/dev/null | tail -n 1 | sed 's/.*=//')"
  fi
  [ -n "$A_DURATION" ] || A_DURATION="$(($(now) - t0))"
  if [ -f "$JD/$tag.log" ]; then
    local label
    label="$(grep -o 'label="[^"]*"' "$JD/$tag.log" 2>/dev/null | tail -n 1 | sed 's/^label="//; s/"$//')"
    [ -n "$label" ] && meta_set "$JD" model_label "$label"
  fi
  return 0
}

response_empty() { ! grep -q '[^[:space:]]' "$JD/$1.response" 2>/dev/null; }

was_denied() { grep -qi -e 'auto-denied' -e 'no output produced' -e 'cannot prompt for' "$JD/$1.err" "$JD/$1.out" 2>/dev/null; }

model_unknown() { grep -qi 'not recognized as a known model' "$JD/$1.err" "$JD/$1.out" 2>/dev/null; }

finish_job() {
  local code="$1" state="$2"
  meta_set "$JD" state "$state"
  meta_set "$JD" exit "$code"
  meta_set "$JD" finished "$(now)"
  printf '%s\n' "$code" >"$JD/exit_code.tmp" && mv "$JD/exit_code.tmp" "$JD/exit_code"
  exit "$code"
}

on_runner_signal() {
  trap - TERM INT HUP
  [ -n "${AGY_PID:-}" ] && kill -TERM "$AGY_PID" 2>/dev/null
  printf 'cancelled\n' >>"$JD/error.txt"
  finish_job "$EX_CANCELLED" cancelled
}

# Images agy saved for this job, newest first: the conversation's artifact
# folder when the conversation id is known, else anything in brain/ that is
# newer than the job's start marker.
find_images() {
  local cid="$1" dir="$AGY_HOME/brain/$1" list="" f
  local -a files
  if [ -n "$cid" ] && [ -d "$dir" ]; then
    list="$(find "$dir" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
      -o -iname '*.webp' -o -iname '*.gif' \) -print 2>/dev/null)"
  elif [ -d "$AGY_HOME/brain" ]; then
    list="$(find "$AGY_HOME/brain" -maxdepth 2 -type f -newer "$JD/started" \( -iname '*.png' -o -iname '*.jpg' \
      -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) -print 2>/dev/null)"
  fi
  [ -n "$list" ] || return 0
  files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$list
EOF
  ls -t "${files[@]}" 2>/dev/null
}

finish_image() {
  local cid="$1" images="" img dest out waited=0
  while :; do
    images="$(find_images "$cid")"
    [ -n "$images" ] && break
    [ "$waited" -lt "$IMAGE_GRACE" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  if [ -z "$images" ]; then
    {
      echo "agy replied, but no generated image was found"
      [ -n "$cid" ] && echo "(looked in $AGY_HOME/brain/$cid)."
    } >"$JD/error.txt"
    finish_job "$EX_NOIMAGE" failed
  fi
  img="$(printf '%s\n' "$images" | head -n 1)"
  printf '%s\n' "$images" >"$JD/images.txt"
  {
    echo
    echo "Image saved: $img"
  } >>"$JD/result.txt"
  out="$(meta_get "$JD" output)"
  if [ -n "$out" ]; then
    case "$out" in
      */) dest="$out$(basename "$img")" ;;
      *) if [ -d "$out" ]; then dest="$out/$(basename "$img")"; else dest="$out"; fi ;;
    esac
    if mkdir -p "$(dirname "$dest")" && cp "$img" "$dest"; then
      echo "Copied to: $dest" >>"$JD/result.txt"
    else
      echo "could not copy the image to $dest" >>"$JD/notes.txt"
    fi
  fi
}

cmd__job_run() {
  JD="${1:-}"
  [ -n "$JD" ] && [ -d "$JD" ] || exit 1
  printf '%s\n' "$$" >"$JD/pid"
  : >"$JD/started"
  local pgid
  pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  [ -n "$pgid" ] && meta_set "$JD" pgid "$pgid"
  meta_set "$JD" state running
  meta_set "$JD" started "$(now)"
  AGY_PID=""
  trap on_runner_signal TERM INT HUP

  AGY="$(find_agy)" || {
    printf 'agy is not installed or not on PATH. Install it with: %s\n' "$INSTALL_HINT" >"$JD/error.txt"
    finish_job "$EX_NOAGY" failed
  }
  detect_json_helper
  meta_set "$JD" json_helper "$JSON_HELPER"
  cd "$(meta_get "$JD" cwd)" 2>/dev/null || {
    printf 'working directory %s does not exist\n' "$(meta_get "$JD" cwd)" >"$JD/error.txt"
    finish_job "$EX_FAIL" failed
  }

  BASE_ARGS=()
  local a
  while IFS= read -r -d '' a; do BASE_ARGS+=("$a"); done <"$JD/agy_args"
  local prompt resume kind tag=run1 cid
  prompt="$(cat "$JD/prompt.txt")"
  resume="$(meta_get "$JD" resume)"
  kind="$(meta_get "$JD" kind)"

  if [ -n "$resume" ]; then
    attempt run1 "$prompt" --conversation "$resume"
  else
    attempt run1 "$prompt"
  fi

  # A built-in alias whose model agy no longer offers: retry once with the
  # newest model of the same family and thinking level.
  local fam lvl succ i=0
  fam="$(meta_get "$JD" family)"
  lvl="$(meta_get "$JD" level)"
  if [ "$A_RC" -ne 0 ] && [ -n "$fam" ] && model_unknown run1; then
    succ="$(find_successor "$fam" "$lvl")"
    if [ -n "$succ" ] && [ "$succ" != "$(meta_get "$JD" model)" ]; then
      while [ "$i" -lt "${#BASE_ARGS[@]}" ]; do
        [ "${BASE_ARGS[$i]}" = --model ] && BASE_ARGS[$((i + 1))]="$succ"
        i=$((i + 1))
      done
      echo "$(meta_get "$JD" model) is no longer offered by agy; used $succ instead (update the plugin for a refreshed alias table)." >>"$JD/notes.txt"
      meta_set "$JD" model "$succ"
      tag=run2
      if [ -n "$resume" ]; then
        attempt run2 "$prompt" --conversation "$resume"
      else
        attempt run2 "$prompt"
      fi
    fi
  fi

  cid="$A_CID"
  [ -n "$cid" ] || cid="$resume"
  [ -n "$cid" ] && meta_set "$JD" conversation "$cid"
  meta_set "$JD" duration "$(fmt_secs "$A_DURATION")"
  [ -n "$A_TOKENS" ] && meta_set "$JD" tokens "$A_TOKENS"

  if [ "$A_RC" -ne 0 ] || [ "$A_STATUS" = ERROR ]; then
    {
      echo "agy failed (exit $A_RC)."
      if [ -s "$JD/$tag.err" ]; then
        sed -n '1,40p' "$JD/$tag.err"
      elif [ -n "$A_ERROR" ]; then
        echo "$A_ERROR"
      fi
      if model_unknown "$tag" || grep -qi 'invalid model selection' "$JD/$tag.err" 2>/dev/null; then
        echo
        echo "Run \`$RUN_CMD models\` for the aliases this plugin knows and the models your agy account offers."
      fi
    } >"$JD/error.txt"
    local code="$A_RC"
    [ "$code" -ne 0 ] || code="$EX_FAIL"
    finish_job "$code" failed
  fi

  # agy auto-denies permission prompts in headless mode and then stops
  # without replying. Resume the same conversation once and ask for the
  # final answer instead.
  if response_empty "$tag" && was_denied "$tag" && [ -n "$cid" ] && [ "$(meta_get "$JD" recover)" != 0 ]; then
    local denied_tag="$tag"
    tag=recover
    attempt recover "$RECOVERY_PROMPT" --conversation "$cid"
    if [ "$A_RC" -eq 0 ] && ! response_empty recover; then
      echo "agy stopped after a permission it could not get in headless mode (e.g. a shell command); its final report was recovered from the same conversation." >>"$JD/notes.txt"
      meta_set "$JD" recovered 1
    else
      tag="$denied_tag"
    fi
  fi

  if response_empty "$tag"; then
    {
      echo "agy finished without a reply."
      if was_denied "$tag"; then
        echo "It tried something that needs a permission this headless run cannot grant (agy auto-denies those), most likely a shell command."
      fi
      [ -s "$JD/$tag.err" ] && { echo "agy said:"; sed -n '1,20p' "$JD/$tag.err"; }
      echo "Any file edits it made before stopping are still in the working tree (check git status / git diff)."
      [ -n "$cid" ] && echo "Continue the conversation with --resume $cid."
    } >"$JD/error.txt"
    finish_job "$EX_NOOUTPUT" failed
  fi

  cp "$JD/$tag.response" "$JD/result.txt"
  [ -n "$(tail -c 1 "$JD/result.txt")" ] && echo >>"$JD/result.txt"
  if [ "$kind" = image ]; then
    finish_image "$cid"
  fi
  finish_job 0 done
}

# ------------------------------------------------------ building requests ---

TASK_NOTE='[Delegated from Claude Code: headless agy run]
- Nobody can answer questions or approve permission prompts during this run.
- Do not run shell or terminal commands: they are denied in this session, and a denied command ends the run before you can reply.
- Use your file tools to read and edit files in the workspace.
- Finish with a short report: what you changed (file paths), anything you could not do, and the exact commands someone should run to verify the work.'

READONLY_NOTE='[Delegated from Claude Code: headless agy run]
- Nobody can answer questions or approve permission prompts during this run.
- This is read-only: do not modify any files and do not run shell or terminal commands (a denied command ends the run before you can reply). Reading files and web search are fine.'

RESEARCH_INTRO='Conduct a thorough research investigation of the topic below. Use web search and other read-only tools where they help, prefer authoritative and recent sources, and say when information may be outdated or disputed.

Structure the answer with these sections: Summary, Background, Key findings, Disagreements and open questions, Caveats, Sources (with URLs).'

REVIEW_FOCUS_DEFAULT='Review this change for correctness bugs, edge cases, security issues, error handling and maintainability.'

# Options shared by ask / task / research / review / image.
parse_run_opts() {
  O_MODEL=""
  O_EFFORT=""
  O_RESUME=""
  O_CD=""
  O_STDIN=0
  O_BACKGROUND=0
  O_WAIT="$WAIT_DEFAULT"
  O_RAW=0
  O_RECOVER=1
  O_NAME=""
  O_OUTPUT=""
  O_BASE=""
  O_UNTRACKED=1
  O_EXTRA=()
  O_POS=()
  local kind="$1" opt val
  shift
  while [ $# -gt 0 ]; do
    opt="$1"
    val=""
    case "$opt" in
      --*=*) val="${opt#*=}"; opt="${opt%%=*}" ;;
    esac
    case "$opt" in
      -m | --model | -e | --effort | --thinking | --resume | --conversation | -C | --cd | --add-dir | \
        --agent | --mode | --timeout | --json-schema | --project | --agy-arg | --wait | --name | \
        -o | --output | --base)
        if [ "$1" = "$opt" ]; then
          [ $# -ge 2 ] || usage_error "$opt needs a value"
          val="$2"
          shift 2
        else
          shift
        fi
        [ -n "$val" ] || usage_error "$opt needs a non-empty value" ;;
      *) shift ;;
    esac
    case "$opt" in
      -m | --model) O_MODEL="$val" ;;
      -e | --effort | --thinking) O_EFFORT="$val" ;;
      --resume | --conversation) O_RESUME="$val" ;;
      -C | --cd)
        [ -d "$val" ] || usage_error "--cd: no such directory: $val"
        O_CD="$(cd "$val" && pwd)" ;;
      --add-dir)
        [ -d "$val" ] || usage_error "--add-dir: no such directory: $val"
        O_EXTRA+=(--add-dir "$(cd "$val" && pwd)") ;;
      --sandbox) O_EXTRA+=(--sandbox) ;;
      --agent) O_EXTRA+=(--agent "$val") ;;
      --mode)
        case "$val" in
          plan | accept-edits) O_EXTRA+=(--mode "$val") ;;
          *) usage_error "--mode $val is not supported here (use plan or accept-edits); this plugin never switches agy to auto-approval" ;;
        esac ;;
      --timeout) O_EXTRA+=(--print-timeout "$val") ;;
      --json-schema) O_EXTRA+=(--json-schema "$val") ;;
      --project) O_EXTRA+=(--project "$val") ;;
      --agy-arg)
        case "$val" in
          --dangerously* | -dangerously*)
            usage_error "$val is refused: this plugin never bypasses agy's permission prompts. Run agy yourself if you really want that." ;;
          -p | --print | --print=* | --prompt | --prompt=* | -i | --prompt-interactive* | --output-format* | \
            --input-format* | --remote-control* | --model* | --effort* | --conversation* | -c | --continue* | \
            --log-file* | --mode*)
            usage_error "$val is managed by the wrapper; use its own options instead (see help)" ;;
        esac
        O_EXTRA+=("$val") ;;
      --dangerously*)
        usage_error "$opt is refused: this plugin never bypasses agy's permission prompts. Run agy yourself if you really want that." ;;
      --stdin) O_STDIN=1 ;;
      --background | --bg) O_BACKGROUND=1 ;;
      --wait)
        case "$val" in *[!0-9]*) usage_error "--wait needs whole seconds" ;; esac
        O_WAIT="$val" ;;
      --raw) O_RAW=1 ;;
      --no-recover) O_RECOVER=0 ;;
      --name) O_NAME="$val" ;;
      -o | --output) O_OUTPUT="$(abspath "$val")" ;;
      --base) O_BASE="$val" ;;
      --no-untracked) O_UNTRACKED=0 ;;
      --)
        O_POS+=("$@")
        break ;;
      -?*) usage_error "unknown option '$opt' for $kind (put the text after -- if it starts with a dash)" ;;
      *)
        O_POS+=("$opt" "$@")
        break ;;
    esac
  done
  case "$kind" in
    image) ;;
    *) [ -z "$O_NAME" ] && [ -z "$O_OUTPUT" ] || usage_error "--name / --output only apply to image" ;;
  esac
  case "$kind" in
    review) ;;
    *) [ -z "$O_BASE" ] && [ "$O_UNTRACKED" = 1 ] || usage_error "--base / --no-untracked only apply to review" ;;
  esac
}

# The user's text: positional words, then (with --stdin) everything on stdin.
request_text() {
  local text="${O_POS[*]+${O_POS[*]}}" input
  if [ "$O_STDIN" = 1 ]; then
    input="$(cat)"
    if [ -n "$text" ]; then
      text="$text

$input"
    else
      text="$input"
    fi
  fi
  printf '%s' "$text"
}

git_diff_text() {
  local base_ref="$1" mb
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$EX_FAIL" "review needs a git repository ($(pwd) is not one)"
  if [ -n "$base_ref" ]; then
    git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || usage_error "--base: unknown git ref '$base_ref'"
    mb="$(git merge-base "$base_ref" HEAD 2>/dev/null)" || die "$EX_FAIL" "no merge base between $base_ref and HEAD"
    REVIEW_DESC="changes since this branch left $base_ref (merge base ${mb:0:12}), committed and uncommitted"
    git -c core.quotepath=off diff --no-color --no-ext-diff "$mb"
  elif git rev-parse --verify --quiet HEAD >/dev/null; then
    REVIEW_DESC="uncommitted changes (staged and unstaged) against HEAD"
    git -c core.quotepath=off diff --no-color --no-ext-diff HEAD
  else
    REVIEW_DESC="uncommitted changes (repository has no commits yet)"
    git -c core.quotepath=off diff --no-color --no-ext-diff --cached
    git -c core.quotepath=off diff --no-color --no-ext-diff
  fi
  if [ "$O_UNTRACKED" = 1 ]; then
    git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
      git -c core.quotepath=off diff --no-color --no-ext-diff --no-index -- /dev/null "$f"
    done
  fi
  return 0
}

# start_run <kind> <args...>: build the request, create the job, launch it.
start_run() {
  local kind="$1" text prompt bytes
  shift
  parse_run_opts "$kind" "$@"
  require_agy
  resolve_model "$O_MODEL" "$O_EFFORT"
  [ -n "$O_CD" ] && { cd "$O_CD" || usage_error "cannot cd to $O_CD"; }
  text="$(request_text)"

  case "$kind" in
    ask)
      [ -n "$text" ] || usage_error "ask needs a question (as arguments or with --stdin)"
      prompt="$text" ;;
    task)
      [ -n "$text" ] || usage_error "task needs a task description (as arguments or with --stdin)"
      if [ "$O_RAW" = 1 ]; then prompt="$text"; else prompt="$TASK_NOTE

Task:
$text"; fi ;;
    research)
      [ -n "$text" ] || usage_error "research needs a topic (as arguments or with --stdin)"
      prompt="$RESEARCH_INTRO

Topic: $text"
      [ "$O_RAW" = 1 ] || prompt="$READONLY_NOTE

$prompt" ;;
    review)
      local diff focus="$text" tmp
      tmp="$(mktemp "${TMPDIR:-/tmp}/agy-review.XXXXXX")" || die "$EX_FAIL" "mktemp failed"
      git_diff_text "$O_BASE" >"$tmp" # not in a subshell: sets REVIEW_DESC
      diff="$(cat "$tmp")"
      rm -f "$tmp"
      [ -n "$diff" ] || die "$EX_FAIL" "nothing to review: no $REVIEW_DESC in $(pwd). Make or stage some changes, or pass --base <branch>."
      [ -n "$focus" ] || focus="$REVIEW_FOCUS_DEFAULT"
      REVIEW_DIFF="$diff"
      prompt="You are reviewing a code change in this repository: $REVIEW_DESC.
$focus
Report findings ordered by severity, each with file:line, the problem and a suggested fix. If the change looks good, say so briefly. You may read files in the workspace for context." ;;
    image)
      [ -n "$text" ] || usage_error "image needs a description (as arguments or with --stdin)"
      prompt="Generate an image with your image generation tool. Description: $text"
      [ -n "$O_NAME" ] && prompt="$prompt
Save it with the file name \"$O_NAME\"."
      prompt="$prompt
When it is saved, reply with one short line describing the result." ;;
  esac

  create_job "$kind"
  meta_set "$JD" cwd "$(pwd)"
  meta_set "$JD" model "$R_MODEL"
  meta_set "$JD" effort "$R_EFFORT"
  meta_set "$JD" family "$R_FAMILY"
  meta_set "$JD" level "$R_LEVEL"
  meta_set "$JD" resume "$O_RESUME"
  meta_set "$JD" recover "$O_RECOVER"
  meta_set "$JD" output "$O_OUTPUT"
  printf '%s\n' "$text" >"$JD/request.txt"

  local -a args
  args=()
  [ -n "$R_MODEL" ] && args+=(--model "$R_MODEL")
  [ -n "$R_EFFORT" ] && args+=(--effort "$R_EFFORT")
  args+=(${O_EXTRA[@]+"${O_EXTRA[@]}"})

  if [ "$kind" = review ]; then
    [ "$O_RAW" = 1 ] || prompt="$prompt
$READONLY_NOTE"
    bytes="$(byte_len "$REVIEW_DIFF")"
    if [ $(($(byte_len "$prompt") + bytes)) -gt "$MAX_ARG_BYTES" ]; then
      mkdir -p "$JD/input"
      printf '%s\n' "$REVIEW_DIFF" >"$JD/input/review.diff"
      args+=(--add-dir "$JD/input")
      prompt="$prompt

The diff is too large to inline ($bytes bytes, $(printf '%s\n' "$REVIEW_DIFF" | wc -l | tr -d ' ') lines). Read the whole file $JD/input/review.diff before reviewing."
    else
      prompt="$prompt

Diff:
\`\`\`diff
$REVIEW_DIFF
\`\`\`"
    fi
  fi

  bytes="$(byte_len "$prompt")"
  if [ "$bytes" -gt "$MAX_ARG_BYTES" ]; then
    # Too long for one command-line argument: hand it over as a file.
    mkdir -p "$JD/input"
    printf '%s\n' "$prompt" >"$JD/input/request.md"
    args+=(--add-dir "$JD/input")
    prompt="Your full instructions are in the file $JD/input/request.md ($bytes bytes). Read the whole file first, then follow it exactly as if it were this message."
  fi
  printf '%s\n' "$prompt" >"$JD/prompt.txt"
  : >"$JD/agy_args"
  [ "${#args[@]}" -eq 0 ] || printf '%s\0' "${args[@]}" >"$JD/agy_args"

  launch_job
  local what="$kind"
  [ -n "$R_MODEL" ] && what="$what, model $R_MODEL" || what="$what, default model"
  [ -n "$R_EFFORT" ] && what="$what, effort $R_EFFORT"
  if [ "$O_BACKGROUND" = 1 ]; then
    printf 'Started agy job %s (%s) in %s.\n' "$JOB_ID" "$what" "$(pwd)"
    printf 'Wait for it:  %s wait %s\n' "$RUN_CMD" "$JOB_ID"
    printf 'Check on it:  %s status %s\n' "$RUN_CMD" "$JOB_ID"
    printf 'Get result:   %s result %s\n' "$RUN_CMD" "$JOB_ID"
    printf 'Stop it:      %s cancel %s\n' "$RUN_CMD" "$JOB_ID"
    return 0
  fi
  note "job $JOB_ID started ($what)"
  show_finished_or_wait "$JD" "$O_WAIT"
}

# --------------------------------------------------------------- commands ---

cmd_check() {
  local path version models_out rc auth=missing count=0 err="" dm warnings="" detach=nohup
  detect_json_helper
  command -v perl >/dev/null 2>&1 && detach=perl
  command -v setsid >/dev/null 2>&1 && detach=setsid
  if [ -f "$AGY_HOME/settings.json.agy-plugin.bak" ]; then
    warnings="\"Found $(j_esc "$AGY_HOME/settings.json.agy-plugin.bak") left by the old antigravity-plugin-cc (it patched settings.json for --model). Compare it with settings.json, keep the one you want and delete the .bak; this plugin never touches settings.json.\""
  fi
  dm="$(default_model 2>/dev/null || true)"
  if ! path="$(find_agy)"; then
    printf '{\n  "installed": false,\n  "path": "",\n  "version": "",\n  "auth": "unknown",\n  "models_available": 0,\n  "default_model": "",\n  "json_helper": "%s",\n  "detach": "%s",\n  "state_dir": "%s",\n  "plugin_version": "%s",\n  "warnings": [%s],\n  "error": "agy not found; install with: %s"\n}\n' \
      "$JSON_HELPER" "$detach" "$(j_esc "$STATE_DIR")" "$AGY_PLUGIN_VERSION" "$warnings" "$(j_esc "$INSTALL_HINT")"
    return 0
  fi
  version="$(run_with_timeout 20 "$path" --version </dev/null 2>/dev/null | head -n 1)"
  models_out="$(run_with_timeout 45 "$path" models </dev/null 2>&1)"
  rc=$?
  count="$(printf '%s\n' "$models_out" | grep -c "$(printf '\t')" || true)"
  if [ "$rc" -eq 0 ] && [ "$count" -gt 0 ]; then
    auth=ok
  else
    auth=error
    err="$(printf '%s\n' "$models_out" | grep -v '^Fetching' | head -n 3 | tr '\n' ' ')"
    [ -n "$err" ] || err="agy models failed (exit $rc)"
    err="$err -- run \`agy\` once in a terminal to sign in, or set ANTIGRAVITY_API_KEY"
  fi
  printf '{\n  "installed": true,\n  "path": "%s",\n  "version": "%s",\n  "auth": "%s",\n  "models_available": %s,\n  "default_model": "%s",\n  "json_helper": "%s",\n  "detach": "%s",\n  "state_dir": "%s",\n  "plugin_version": "%s",\n  "warnings": [%s],\n  "error": "%s"\n}\n' \
    "$(j_esc "$path")" "$(j_esc "$version")" "$auth" "${count:-0}" "$(j_esc "$dm")" "$JSON_HELPER" "$detach" \
    "$(j_esc "$STATE_DIR")" "$AGY_PLUGIN_VERSION" "$warnings" "$(j_esc "$err")"
}

cmd_models() {
  local out dm
  print_model_table
  dm="$(default_model 2>/dev/null || true)"
  echo
  [ -n "$dm" ] && echo "Your agy default (used when --model is omitted): $dm"
  if AGY="$(find_agy)"; then
    echo "Models your agy account offers right now (agy models):"
    if out="$(run_with_timeout 45 "$AGY" models </dev/null 2>&1)"; then
      printf '%s\n' "$out" | grep -v '^Fetching' | awk -F '\t' 'NF >= 2 { printf "  %-28s %s\n", $1, $2; next } NF { print "  " $0 }'
    else
      printf '%s\n' "$out" | sed 's/^/  /'
      return "$EX_FAIL"
    fi
  else
    echo "agy is not installed, so the live model list is unavailable ($INSTALL_HINT)."
  fi
}

cmd_resolve_model() {
  parse_run_opts resolve-model "$@"
  resolve_model "${O_MODEL:-${O_POS[0]:-}}" "$O_EFFORT"
  printf 'model=%s\neffort=%s\n' "$R_MODEL" "$R_EFFORT"
}

cmd_usage() {
  require_agy
  local out
  out="$(run_with_timeout 60 "$AGY" -p /usage </dev/null 2>&1)" || {
    printf '%s\n' "$out" >&2
    return "$EX_FAIL"
  }
  printf '%s\n' "$out" | awk -F '\t' 'NF >= 3 { printf "%-24s %-32s %6s  resets %s\n", $1, $2, $3, $4; next } { print }'
}

human_age() {
  local s="$1"
  if [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}

job_json() {
  local jd="$1"
  printf '{"id":"%s","kind":"%s","state":"%s","exit":"%s","created":%s,"finished":"%s","model":"%s","model_label":"%s","conversation":"%s","cwd":"%s","dir":"%s"}' \
    "$(j_esc "$(meta_get "$jd" id)")" "$(meta_get "$jd" kind)" "$(job_state "$jd")" \
    "$(cat "$jd/exit_code" 2>/dev/null)" "$(meta_get "$jd" created)" "$(meta_get "$jd" finished)" \
    "$(j_esc "$(meta_get "$jd" model)")" "$(j_esc "$(meta_get "$jd" model_label)")" \
    "$(meta_get "$jd" conversation)" "$(j_esc "$(meta_get "$jd" cwd)")" "$(j_esc "$jd")"
}

cmd_status() {
  local ref="" all=0 json=0 jd ids n=0 first=1 state age created req model
  while [ $# -gt 0 ]; do
    case "$1" in
      --all | -a) all=1 ;;
      --json) json=1 ;;
      -*) usage_error "unknown option '$1' for status" ;;
      *) ref="$1" ;;
    esac
    shift
  done
  if [ -n "$ref" ]; then
    resolve_job "$ref"
    if [ "$json" = 1 ]; then job_json "$JD"; echo; return 0; fi
    state="$(job_state "$JD")"
    created="$(meta_get "$JD" created)"
    echo "Job:          $JOB_ID ($(meta_get "$JD" kind))"
    echo "State:        $state$(job_done "$JD" && printf ' (exit %s)' "$(cat "$JD/exit_code")")"
    echo "Started:      $(human_age $(($(now) - ${created:-0}))) ago"
    [ -n "$(meta_get "$JD" duration)" ] && echo "agy time:     $(meta_get "$JD" duration)s"
    model="$(meta_get "$JD" model_label)"
    [ -n "$model" ] || model="$(meta_get "$JD" model)"
    echo "Model:        ${model:-agy default}"
    [ -n "$(meta_get "$JD" effort)" ] && echo "Effort:       $(meta_get "$JD" effort)"
    [ -n "$(meta_get "$JD" conversation)" ] && echo "Conversation: $(meta_get "$JD" conversation)"
    echo "Directory:    $(meta_get "$JD" cwd)"
    echo "Job files:    $JD"
    echo "Request:"
    sed -n '1,8p' "$JD/request.txt" 2>/dev/null | cut -c 1-200 | sed 's/^/  /'
    if [ "$state" = failed ] && [ -s "$JD/error.txt" ]; then
      echo "Error:"
      sed -n '1,12p' "$JD/error.txt" | sed 's/^/  /'
    fi
    return 0
  fi
  ids="$(ls -1 "$JOBS_DIR" 2>/dev/null | sort -r)"
  if [ "$json" = 1 ]; then
    printf '['
    for id in $ids; do
      jd="$JOBS_DIR/$id"
      [ -f "$jd/meta" ] || continue
      n=$((n + 1))
      [ "$all" = 1 ] || [ "$n" -le 20 ] || break
      [ "$first" = 1 ] || printf ','
      first=0
      job_json "$jd"
    done
    printf ']\n'
    return 0
  fi
  if [ -z "$ids" ]; then
    echo "No agy jobs yet."
    return 0
  fi
  printf '%-21s %-9s %-8s %-5s %-24s %s\n' JOB STATE KIND AGE MODEL REQUEST
  for id in $ids; do
    jd="$JOBS_DIR/$id"
    [ -f "$jd/meta" ] || continue
    n=$((n + 1))
    if [ "$all" = 0 ] && [ "$n" -gt 20 ]; then
      echo "(older jobs hidden; use --all)"
      break
    fi
    created="$(meta_get "$jd" created)"
    age="$(human_age $(($(now) - ${created:-0})))"
    model="$(meta_get "$jd" model_label)"
    [ -n "$model" ] || model="$(meta_get "$jd" model)"
    req="$(head -n 1 "$jd/request.txt" 2>/dev/null | cut -c 1-60)"
    printf '%-21s %-9s %-8s %-5s %-24s %s\n' "$id" "$(job_state "$jd")" "$(meta_get "$jd" kind)" "$age" \
      "$(printf '%s' "${model:-default}" | cut -c 1-24)" "$req"
  done
}

cmd_result() {
  resolve_job "${1:-last}"
  if ! job_done "$JD"; then
    if [ "$(job_state "$JD")" = lost ]; then
      die "$EX_FAIL" "agy job $JOB_ID stopped without recording a result (runner log: $JD/runner.log)"
    fi
    still_running_message "$JOB_ID" ""
    return "$EX_RUNNING"
  fi
  print_result "$JD"
}

cmd_wait() {
  local ref="" secs="$WAIT_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] || usage_error "--timeout needs seconds"; secs="$2"; shift 2 ;;
      --timeout=*) secs="${1#*=}"; shift ;;
      -*) usage_error "unknown option '$1' for wait" ;;
      *) ref="$1"; shift ;;
    esac
  done
  case "$secs" in '' | *[!0-9]*) usage_error "--timeout needs whole seconds (0 = no limit)" ;; esac
  resolve_job "${ref:-last}"
  show_finished_or_wait "$JD" "$secs"
}

cancel_one() {
  local jd="$1" pid pgid apid i
  job_done "$jd" && { echo "agy job $(meta_get "$jd" id) already finished ($(meta_get "$jd" state))."; return 0; }
  pid="$(cat "$jd/pid" 2>/dev/null)"
  pgid="$(meta_get "$jd" pgid)"
  apid="$(cat "$jd/agy.pid" 2>/dev/null)"
  if [ -n "$pid" ] && [ -n "$pgid" ] && [ "$pid" = "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null
  else
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    [ -n "$apid" ] && kill -TERM "$apid" 2>/dev/null
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    job_done "$jd" && break
    sleep 0.5
  done
  if ! job_done "$jd"; then
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    [ -n "$apid" ] && kill -KILL "$apid" 2>/dev/null
    meta_set "$jd" state cancelled
    meta_set "$jd" finished "$(now)"
    printf '%s\n' "$EX_CANCELLED" >"$jd/exit_code"
  fi
  echo "Cancelled agy job $(meta_get "$jd" id)."
}

cmd_cancel() {
  local ref="${1:-}" id
  [ -n "$ref" ] || usage_error "cancel needs a job id, 'last' or 'all'"
  if [ "$ref" = all ]; then
    for id in $(ls -1 "$JOBS_DIR" 2>/dev/null); do
      job_done "$JOBS_DIR/$id" || cancel_one "$JOBS_DIR/$id"
    done
    return 0
  fi
  resolve_job "$ref"
  cancel_one "$JD"
}

cmd_prune() {
  local days="$RETENTION_DAYS"
  case "${1:-}" in
    --days) days="${2:-}" ;;
    --days=*) days="${1#*=}" ;;
    "") ;;
    *) usage_error "usage: prune [--days N]" ;;
  esac
  case "$days" in '' | *[!0-9]*) usage_error "--days needs a whole number" ;; esac
  prune_jobs "$days"
  echo "Removed finished agy jobs older than $days day(s) from $JOBS_DIR."
}

cmd_help() {
  cat <<HELP
agy-run.sh $AGY_PLUGIN_VERSION: Claude Code wrapper for the Google Antigravity CLI (agy)

Slash commands (Claude Code)
  /agy:setup                    check agy is installed and signed in
  /agy:ask [opts] <question>    one-shot question, answer returned verbatim
  /agy:delegate [opts] <task>   hand a task to an agy agent (agy:runner subagent)
  /agy:research [opts] <topic>  structured web research
  /agy:review [opts] [focus]    review the current diff (--base <ref> for a branch)
  /agy:image [opts] <prompt>    generate an image (--name, --output)
  /agy:status [job]  /agy:result [job]  /agy:cancel <job>   background jobs
  /agy:models  /agy:usage  /agy:help

Wrapper usage
  bash agy-run.sh ask      [opts] <question...>
  bash agy-run.sh task     [opts] <task...>        (alias: delegate)
  bash agy-run.sh start    [opts] <task...>        (task --background)
  bash agy-run.sh research [opts] <topic...>
  bash agy-run.sh review   [opts] [--base REF] [--no-untracked] [focus...]
  bash agy-run.sh image    [opts] [--name SLUG] [--output PATH] <description...>
  bash agy-run.sh status [JOB|--all] [--json] | result [JOB] | wait [JOB] [--timeout S]
  bash agy-run.sh cancel JOB|last|all | prune [--days N]
  bash agy-run.sh check | models | usage | help | version

Options for ask / task / start / research / review / image
  -m, --model NAME        alias, display name or model id (table below)
  -e, --effort LEVEL      thinking level: low | medium | high (also --thinking)
  --resume ID             continue an earlier agy conversation (follow-ups)
  -C, --cd DIR            run agy in DIR (its workspace); default: current dir
  --add-dir DIR           give agy access to another directory (repeatable)
  --sandbox               agy's terminal sandbox
  --mode plan|accept-edits    agy execution mode
  --agent NAME            run one of agy's agents (see: agy agents)
  --timeout DUR           agy --print-timeout, e.g. 20m
  --json-schema SCHEMA    ask agy for structured output
  --stdin                 read the text from stdin (use a quoted heredoc)
  --background            start the job and return its id immediately
  --wait SECONDS          how long a foreground call waits (default $WAIT_DEFAULT; 0 = no limit)
  --raw                   task/research/review: send the text without the headless note
  --no-recover            don't resume a run that a denied permission cut short
  Options go before the text; use -- if the text starts with a dash.

HELP
  print_model_table
  cat <<HELP

How it works
  Each call is a job under $JOBS_DIR. agy runs detached with stdin closed,
  --output-format json and its native --model / --effort flags, so parallel
  calls never block each other and settings.json is never modified.
  Foreground calls wait up to --wait seconds; a job that is still running
  keeps going and can be collected with wait / result.
  Headless agy can read and edit files in its workspace but auto-denies shell
  commands. task asks agy to work with file tools only and report the
  commands to verify; if a run still stops on a denied permission, the
  wrapper resumes the conversation once to get the final report.

Exit codes
  0 ok · 1 agy error · 3 agy gave no reply · 4 no image found · 64 usage error
  75 job still running · 127 agy not installed · 130 job cancelled
HELP
}

main() {
  local sub="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    check | setup) cmd_check ;;
    ask) start_run ask "$@" ;;
    task | delegate) start_run task "$@" ;;
    start) start_run task --background "$@" ;;
    research) start_run research "$@" ;;
    review) start_run review "$@" ;;
    image) start_run image "$@" ;;
    status | jobs) cmd_status "$@" ;;
    result) cmd_result "$@" ;;
    wait) cmd_wait "$@" ;;
    cancel) cmd_cancel "$@" ;;
    prune) cmd_prune "$@" ;;
    models) cmd_models ;;
    usage) cmd_usage ;;
    resolve-model) cmd_resolve_model "$@" ;;
    _job-run) cmd__job_run "$@" ;;
    version | --version | -V) echo "agy-run.sh $AGY_PLUGIN_VERSION" ;;
    help | -h | --help) cmd_help ;;
    *)
      printf "error: unknown subcommand '%s'\n\n" "$sub" >&2
      cmd_help >&2
      exit "$EX_USAGE" ;;
  esac
}

# Skip dispatch when sourced, so tests can call functions directly.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
