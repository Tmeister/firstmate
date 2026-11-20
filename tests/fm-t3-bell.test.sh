#!/usr/bin/env bash
# tests/fm-t3-bell.test.sh - bin/fm-t3-bell.sh against the fake T3 server
# (tests/t3-fake-server.mjs): the opt-in switch, one doorbell per queued
# sequence under one client request id, the settled-thread, grace, and away
# guards, single instance, the off switch, and one shared watcher arm.
# Each case runs a copy of bin/ whose fm-watch-arm.sh is a recording stub, so
# no real watcher runs and nothing reaches a live server.
set -u

unset FM_T3CODE_TOKEN_FILE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_BACKEND

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-bell-tests)
t3_fake_start "$TMP_ROOT/server"
BELL_PID=
cleanup() {
  if [ -n "$BELL_PID" ]; then
    kill "$BELL_PID" 2>/dev/null || true
    wait "$BELL_PID" 2>/dev/null || true
  fi
  cat "$TMP_ROOT"/*/arms 2>/dev/null | while read -r pid; do kill "$pid" 2>/dev/null || true; done
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

# bell_case <name> <thread-status>: a home (FM_HOME) with its own copy of bin/,
# the switch on, a credential, and one thread `thread-sup` in <status>.
bell_case() {
  local name=$1 status=$2 run=null
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
  cp -R "$ROOT/bin" "$HOME_DIR/bin"
  cat > "$HOME_DIR/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
echo "\$\$" >> '$CASE_DIR/arms'
exec sleep "\${FM_TEST_ARM_SECS:-600}"
SH
  chmod +x "$HOME_DIR/bin/fm-watch-arm.sh"
  : > "$HOME_DIR/config/t3-bell"
  : > "$HOME_DIR/config/supervision-host-off"
  t3_fake_case "$CASE_DIR"
  case "$status" in running) run='"run-1"' ;; esac
  FM_T3_STATUS=$status FM_T3_RUN=$run t3_fake_set '
w = { tokens: w.tokens || [], projects: [], threads: { "thread-sup": {
  threadId: "thread-sup", projectId: "proj-1", status: process.env.FM_T3_STATUS,
  activeRunId: JSON.parse(process.env.FM_T3_RUN), archived: false, worktreePath: null,
  pendingRequestCount: 0, providerInstanceId: "claudeAgent", runtimeMode: "full-access",
  parentThreadId: null, items: [], runs: [] } } };'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
}

queue_row() {  # <seq> [age-seconds]
  printf '%s\t%s\tsignal\tstatus:/x/task.status\tsignal: task.status\n' \
    "$(( $(date +%s) - ${2:-120} ))" "$1" >> "$HOME_DIR/state/.wake-queue"
}

bell_run() {  # [extra env...]
  env FM_HOME="$HOME_DIR" FM_T3_BELL_TICK=1 FM_T3_BELL_GRACE="${GRACE:-0}" "$@" \
    "$HOME_DIR/bin/fm-t3-bell.sh" run thread-sup >/dev/null 2>&1 &
  BELL_PID=$!
}

bell_stop() {
  [ -n "$BELL_PID" ] || return 0
  kill "$BELL_PID" 2>/dev/null || true
  wait "$BELL_PID" 2>/dev/null || true
  BELL_PID=
}

sends() {
  t3_fake_calls t3_thread_send
}

wait_for() {  # <seconds> <command...>
  local n=$(( $1 * 10 ))
  shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}

has_sends() { [ "$(sends | wc -l | tr -d ' ')" -ge "$1" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
arms() { [ -f "$CASE_DIR/arms" ] && [ "$(wc -l < "$CASE_DIR/arms" | tr -d ' ')" -ge "$1" ]; }
log_has() { grep -q "$1" "$HOME_DIR/state/.t3-bell.log" 2>/dev/null; }

# off by default
test_off_by_default() {
  bell_case off idle
  rm -f "$HOME_DIR/config/t3-bell"
  out=$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" start thread-sup 2>&1)
  assert_contains "$out" "t3-bell: off" "start without config/t3-bell does nothing"
  assert_equals "t3-bell: stopped" "$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" status)" "no bell runs when off"
  : > "$HOME_DIR/config/t3-bell"
  rm -f "$HOME_DIR/config/supervision-host-off"
  out=$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" start thread-sup 2>&1) && fail "start ran with the supervision host on"
  assert_contains "$out" "supervision-host-off" "start refuses while the supervision host is on"
  assert_equals "t3-bell: stopped" "$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" status)" "no bell runs beside the supervision host"
  pass "off by default"
}

# one doorbell per queued sequence
test_rings_once_per_sequence() {
  bell_case ring idle
  queue_row 7
  bell_run
  wait_for 10 has_sends 1 || fail "the bell never rang an idle thread with a queued wake"
  sleep 3
  assert_equals 1 "$(sends | wc -l | tr -d ' ')" "one queued sequence rings exactly once"
  call=$(sends | head -n 1)
  tag=$(printf '%s' "$HOME_DIR" | cksum | awk '{print $1}')
  assert_contains "$call" "\"clientRequestId\":\"fm-t3-bell-$tag-7\"" "the request id names the home and the newest sequence"
  assert_contains "$call" "Firstmate operational input waiting" "the message is an operational-input doorbell"
  record=$(printf '%s' "$call" | node -e 'const m = JSON.parse(require("fs").readFileSync(0, "utf8")).message; process.stdout.write(m.split("\x27")[1])')
  case "$record" in "$(cd "$HOME_DIR/state" && pwd -P)/operational-inbox/"*) : ;; *) fail "the doorbell record is not in this home's inbox: $record" ;; esac
  assert_equals watcher "$("$HOME_DIR/bin/fm-operational-input.sh" kind < "$record")" "the doorbell record is a watcher-kind operational input"
  t3_fake_set 'w.threads["thread-sup"].status = "completed"; w.threads["thread-sup"].activeRunId = null;'
  queue_row 8
  wait_for 10 has_sends 2 || fail "a newer queued sequence did not ring again"
  assert_contains "$(sends | tail -n 1)" "fm-t3-bell-$tag-8" "the next sequence gets its own request id"
  bell_stop
  pass "one doorbell per queued sequence"
}

# an acknowledged queue rings nothing
test_empty_queue_rings_nothing() {
  bell_case empty idle
  bell_run
  sleep 3
  assert_equals 0 "$(sends | wc -l | tr -d ' ')" "an empty queue never rings"
  bell_stop
  pass "an acknowledged queue rings nothing"
}

# guards: busy thread, grace, away mode
test_guards() {
  bell_case busy running
  queue_row 3
  bell_run
  sleep 3
  assert_equals 0 "$(sends | wc -l | tr -d ' ')" "a running thread is not rung"
  t3_fake_set 'w.threads["thread-sup"].status = "idle"; w.threads["thread-sup"].activeRunId = null;'
  wait_for 10 has_sends 1 || fail "the bell did not ring once the thread settled"
  bell_stop

  bell_case blocked idle
  t3_fake_set 'w.threads["thread-sup"].pendingRequestCount = 1;'
  queue_row 3
  bell_run
  sleep 3
  assert_equals 0 "$(sends | wc -l | tr -d ' ')" "a thread waiting on a pending request is not rung"
  bell_stop

  bell_case grace idle
  queue_row 3 5
  GRACE=3600 bell_run
  sleep 3
  assert_equals 0 "$(sends | wc -l | tr -d ' ')" "a wake younger than the grace is left to a live session"
  bell_stop

  bell_case away idle
  queue_row 3
  : > "$HOME_DIR/state/.afk"
  bell_run
  sleep 3
  assert_equals 0 "$(sends | wc -l | tr -d ' ')" "away mode leaves delivery to the away daemon"
  bell_stop
  pass "guards: busy thread, grace, away mode"
}

# unconfirmed sends retry under the same request id
test_retry_keeps_request_id() {
  bell_case retry idle
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "unavailable", message: "send unavailable" } };'
  queue_row 4
  bell_run FM_T3_BELL_RETRY=1
  wait_for 10 log_has 'verdict=unconfirmed' || wait_for 5 log_has 'verdict=send-failed' || fail "the failing send was never attempted"
  t3_fake_set 'delete w.failTools;'
  wait_for 10 log_has 'verdict=empty' || fail "the retry never delivered"
  sleep 2
  ids=$(sends | node -e 'const ids = new Set(require("fs").readFileSync(0, "utf8").trim().split("\n").map((l) => JSON.parse(l).clientRequestId)); process.stdout.write([...ids].join(" "))')
  assert_equals "fm-t3-bell-$(printf '%s' "$HOME_DIR" | cksum | awk '{print $1}')-4" "$ids" "every attempt, failed or not, carries the one request id"
  delivered=$(node -e 'const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).threads["thread-sup"]; process.stdout.write(String((t.items || []).filter((i) => i.type === "user_message").length))' "$T3_FAKE_WORLD")
  assert_equals 1 "$delivered" "the retried delivery lands in the thread once"
  bell_stop
  pass "unconfirmed sends retry under the same request id"
}

# single instance, status, off switch
test_lifecycle_and_off_switch() {
  bell_case lifecycle idle
  out=$(FM_HOME="$HOME_DIR" FM_T3_BELL_TICK=1 "$HOME_DIR/bin/fm-t3-bell.sh" start thread-sup 2>&1)
  assert_contains "$out" "t3-bell: started pid=" "start launches the bell and reports it"
  pid=$(cat "$HOME_DIR/state/.t3-bell.lock/pid")
  assert_contains "$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" status)" "running pid=$pid thread=thread-sup" "status names the running bell and its thread"
  out=$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" start thread-sup 2>&1)
  assert_contains "$out" "running pid=$pid" "a second start finds the running bell"
  out=$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" run thread-sup 2>&1)
  assert_contains "$out" "already running pid=$pid" "a second loop refuses to run beside the first"
  rm -f "$HOME_DIR/config/t3-bell"
  wait_for 10 gone "$pid" || fail "the bell kept running after config/t3-bell was removed"
  assert_equals "t3-bell: stopped" "$(FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-t3-bell.sh" status)" "status reads stopped after the off switch"
  pass "single instance, status, off switch"
}

# one watcher arm, re-armed after it closes
test_one_arm() {
  bell_case arm idle
  : > "$HOME_DIR/state/task-a.meta"
  FM_TEST_ARM_SECS=2 bell_run FM_TEST_ARM_SECS=2
  wait_for 10 arms 1 || fail "the bell did not arm a watcher while supervision was needed"
  sleep 1
  assert_equals 1 "$(wc -l < "$CASE_DIR/arms" | tr -d ' ')" "only one arm runs at a time"
  wait_for 10 arms 2 || fail "the bell did not re-arm after the arm closed"
  rm -f "$HOME_DIR/state/task-a.meta"
  bell_stop

  bell_case noarm idle
  bell_run
  sleep 3
  assert_absent "$CASE_DIR/arms" "a home with nothing to supervise is not armed"
  bell_stop
  pass "one watcher arm, re-armed after it closes"
}

fm_test_run \
  test_off_by_default \
  test_rings_once_per_sequence \
  test_empty_queue_rings_nothing \
  test_guards \
  test_retry_keeps_request_id \
  test_lifecycle_and_off_switch \
  test_one_arm
