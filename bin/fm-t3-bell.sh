#!/usr/bin/env bash
# fm-t3-bell.sh - the T3 doorbell: keeps one watcher cycle alive for a home
# whose supervisor runs in a T3 Code thread, and rings that thread when queued
# wakes go unhandled.
#
# Why it exists: T3 releases an idle agent process after 30 minutes, and every
# Claude arm (bin/fm-claude-stop-autoarm.sh) lives inside that process, so after
# the release the watcher stops and wakes are queued with nobody to announce
# them. The bell runs outside the agent: `start` detaches it into its own
# process group, so T3's process-group kill of the agent does not reach it, and
# a message sent into the thread is what makes T3 restart the agent in the same
# conversation.
#
# Opt-in and off switch: config/t3-bell (any content). Absent, `start` does
# nothing and a running bell exits within one tick.
# The bell also requires config/supervision-host-off: the supervision host
# (docs/supervision-host.md) runs inside the agent process like every other arm,
# and the bell does not yet run it, so a home with the bell runs without it.
#
# Each tick (FM_T3_BELL_TICK seconds, default 10):
#   - Watcher: while the home needs supervision (bin/fm-supervision-lib.sh) and
#     away mode is off, the bell keeps one bin/fm-watch-arm.sh child. An arm
#     attaches to a live watcher rather than starting a second one, so the
#     Stop hook's arm and the bell's arm always share one watcher cycle.
#   - Bell: when main has queued wakes whose oldest row is at least
#     FM_T3_BELL_GRACE seconds old (default 60, which leaves a live Stop hook
#     time to deliver them first) and the thread reads settled (idle, ready, or
#     interrupted, with no pending request), it sends one doorbell into the
#     thread through the adapter's t3_thread_send. The doorbell is an
#     operational-input record (kind watcher, bin/fm-operational-input.sh)
#     telling the supervisor to drain its wake queue.
#     There is one delivery per newest queued sequence, under one client request
#     id derived from the home and that sequence, so a resend lands on the
#     message T3 already committed. A send that is not confirmed is retried with
#     the same id and text every FM_T3_BELL_RETRY seconds (default 300). The
#     delivery record is state/.t3-bell-delivery.
#   - Away mode (state/.afk) leaves the watcher and delivery to the away daemon.
#
# Usage:
#   fm-t3-bell.sh start [--no-wait] [<thread-id>]
#       Launch the loop detached (no-op when config/t3-bell is absent or a bell
#       already runs for this home). The thread is the argument, else
#       this home's one live T3 thread (matched by working directory), resolved
#       by the loop and
#       recorded in state/.t3-bell-thread. Without --no-wait it waits up to
#       FM_T3_BELL_START_WAIT seconds (default 20) and prints the outcome.
#   fm-t3-bell.sh run [<thread-id>]   the loop itself, in the foreground
#   fm-t3-bell.sh stop                stop this home's bell
#   fm-t3-bell.sh status              "running pid=<n> thread=<id>" or "stopped"
# Log: state/.t3-bell.log. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

SWITCH="$CONFIG/t3-bell"
LOCK="$STATE/.t3-bell.lock"
LOG="$STATE/.t3-bell.log"
THREAD_FILE="$STATE/.t3-bell-thread"
DELIVERY="$STATE/.t3-bell-delivery"
TICK=${FM_T3_BELL_TICK:-10}
GRACE=${FM_T3_BELL_GRACE:-60}
RETRY=${FM_T3_BELL_RETRY:-300}
START_WAIT=${FM_T3_BELL_START_WAIT:-20}
case "$TICK" in ''|*[!0-9]*|0) TICK=10 ;; esac
case "$GRACE" in ''|*[!0-9]*) GRACE=60 ;; esac
case "$RETRY" in ''|*[!0-9]*) RETRY=300 ;; esac
case "$START_WAIT" in ''|*[!0-9]*) START_WAIT=20 ;; esac

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# The running bell's pid, from the lock it holds; fails when none runs.
bell_pid() {
  local pid
  pid=$(cat "$LOCK/pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# Main's queued rows: "<count> <oldest-epoch> <newest-seq>", or nothing.
queue_summary() {
  local count
  count=$(fm_wake_actor_pending_count main)
  [ "${count:-0}" -gt 0 ] 2>/dev/null || return 1
  awk -F '\t' -v n="$count" '
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      if (oldest == "" || $1 + 0 < oldest + 0) oldest = $1
      if (newest == "" || $2 + 0 > newest + 0) newest = $2
    }
    END { if (newest != "") print n, oldest, newest }
  ' "$FM_WAKE_QUEUE" 2>/dev/null
}

thread_settled() {  # <thread-id>
  case "$(fm_backend_t3code_probe "$1")" in
    idle|ready|interrupted) return 0 ;;
  esac
  return 1
}

home_tag() {
  printf '%s' "$FM_HOME" | cksum | awk '{print $1}'
}

# One send of the recorded delivery; updates its state line.
send_delivery() {  # <thread-id> <seq> <request-id> <msg-file>
  local thread=$1 seq=$2 id=$3 msg verdict state
  msg=$(cat "$4") || return 1
  verdict=$(FM_T3CODE_CLIENT_REQUEST_ID=$id fm_backend_send_text_submit t3code "$thread" "$msg" 1 0 0 2>>"$LOG")
  case "$verdict" in
    empty) state=accepted ;;
    *) state=retry ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$seq" "$id" "$state" "$(date +%s)" > "$DELIVERY.tmp" \
    && mv -f "$DELIVERY.tmp" "$DELIVERY"
  log "rang thread=$thread seq=$seq id=$id verdict=${verdict:-none}"
}

ring_if_due() {  # <thread-id>
  local thread=$1 summary count oldest newest now d_seq='' d_id='' d_state='' d_at=0 body msg id
  summary=$(queue_summary) || return 0
  read -r count oldest newest <<EOF
$summary
EOF
  now=$(date +%s)
  [ $((now - oldest)) -ge "$GRACE" ] || return 0
  if [ -f "$DELIVERY" ]; then
    IFS="$(printf '\t')" read -r d_seq d_id d_state d_at < "$DELIVERY" || true
  fi
  if [ "$d_seq" = "$newest" ]; then
    [ "$d_state" = retry ] || return 0
    case "$d_at" in ''|*[!0-9]*) d_at=0 ;; esac
    [ $((now - d_at)) -ge "$RETRY" ] || return 0
    thread_settled "$thread" || return 0
    send_delivery "$thread" "$newest" "$d_id" "$DELIVERY.msg"
    return 0
  fi
  thread_settled "$thread" || return 0
  body="T3 doorbell (bin/fm-t3-bell.sh): $count queued wake(s) are waiting for this home's supervisor and no live session delivered them. Handle this as a wake-handling turn: drain the durable wake queue, act on each wake, then run the printed acknowledgement."
  if ! fm_operational_record_write "$STATE" watcher "$body" msg; then
    log "could not publish the doorbell record under $STATE"
    return 0
  fi
  id="fm-t3-bell-$(home_tag)-$newest"
  printf '%s' "$msg" > "$DELIVERY.msg" || return 0
  send_delivery "$thread" "$newest" "$id" "$DELIVERY.msg"
}

ARM_PID=
arm_tick() {
  if [ -n "$ARM_PID" ] && ! kill -0 "$ARM_PID" 2>/dev/null; then
    wait "$ARM_PID" 2>/dev/null
    log "arm pid=$ARM_PID exited status=$?"
    ARM_PID=
  fi
  [ -z "$ARM_PID" ] || return 0
  fm_supervision_needed "$STATE" || return 0
  "$SCRIPT_DIR/fm-watch-arm.sh" >> "$LOG" 2>&1 </dev/null &
  ARM_PID=$!
  log "arm pid=$ARM_PID started"
}

stop_arm() {
  [ -n "$ARM_PID" ] || return 0
  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=
}

# The thread argument, else this home's one live T3 thread. config/t3-bell is
# the explicit T3 selection here, so discovery does not also require the
# workers' backend to be t3code.
resolve_thread() {  # [<thread-id>]
  local thread=${1:-}
  if [ -z "$thread" ]; then
    thread=$(fm_backend_t3code_thread_for_home "$FM_HOME") || return 1
  fi
  [ -n "$thread" ] || return 1
  printf '%s' "$thread"
}

cmd_run() {
  local thread
  mkdir -p "$STATE" || exit 1
  [ -f "$SWITCH" ] || { log "not started: $SWITCH is absent"; exit 0; }
  [ -e "$CONFIG/supervision-host-off" ] || {
    log "not started: the bell needs the supervision host off ($CONFIG/supervision-host-off)"
    exit 1
  }
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "t3-bell: already running pid=${FM_LOCK_HELD_PID:-unknown}"
    exit 0
  fi
  trap 'stop_arm; fm_lock_release "$LOCK"; log "stopped"; exit 0' TERM INT HUP
  fm_backend_source t3code || { fm_lock_release "$LOCK"; exit 1; }
  if ! thread=$(resolve_thread "${1:-}"); then
    log "not started: no single live T3 thread for this home (pass the thread id)"
    rm -f "$THREAD_FILE"
    fm_lock_release "$LOCK"
    exit 1
  fi
  printf '%s\n' "$thread" > "$THREAD_FILE"
  log "started pid=${BASHPID:-$$} thread=$thread tick=${TICK}s grace=${GRACE}s"
  while [ -f "$SWITCH" ]; do
    if [ -e "$STATE/.afk" ]; then
      stop_arm
    else
      arm_tick
      ring_if_due "$thread"
    fi
    sleep "$TICK" &
    wait $! 2>/dev/null || true
  done
  log "off switch: $SWITCH removed"
  stop_arm
  fm_lock_release "$LOCK"
}

cmd_start() {
  local wait=1 thread='' pid deadline monitor_was_on=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-wait) wait=0 ;;
      -*) echo "error: unknown option $1" >&2; exit 2 ;;
      *) thread=$1 ;;
    esac
    shift
  done
  [ -f "$SWITCH" ] || { echo "t3-bell: off ($SWITCH is absent)"; exit 0; }
  [ -e "$CONFIG/supervision-host-off" ] || {
    echo "t3-bell: refused - the bell needs the supervision host off; create $CONFIG/supervision-host-off" >&2
    exit 1
  }
  if pid=$(bell_pid); then
    echo "t3-bell: running pid=$pid thread=$(cat "$THREAD_FILE" 2>/dev/null)"
    exit 0
  fi
  mkdir -p "$STATE" || exit 1
  rm -f "$THREAD_FILE"
  # Own process group plus nohup and detached stdio: T3 ends a released agent
  # with a process-group kill, and that must not reach the bell.
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-t3-bell.sh" run "$thread" >> "$LOG" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  [ "$wait" -eq 1 ] || { echo "t3-bell: starting pid=$pid (log $LOG)"; exit 0; }
  deadline=$(( $(date +%s) + START_WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$THREAD_FILE" ]; then
      echo "t3-bell: started pid=$pid thread=$(cat "$THREAD_FILE")"
      exit 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  echo "t3-bell: FAILED to start; see $LOG" >&2
  exit 1
}

cmd_stop() {
  local pid
  pid=$(bell_pid) || { echo "t3-bell: stopped"; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  echo "t3-bell: stopping pid=$pid"
}

cmd_status() {
  local pid
  if pid=$(bell_pid); then
    echo "t3-bell: running pid=$pid thread=$(cat "$THREAD_FILE" 2>/dev/null)"
  else
    echo "t3-bell: stopped"
  fi
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  run) shift; cmd_run "$@" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
