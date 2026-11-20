#!/usr/bin/env bash
# tests/fm-remote-secondmate-t3code.test.sh - the host side of a remote T3
# second mate: bin/fm-remote-secondmate-control.sh driving a host-local T3
# server (tests/t3-fake-server.mjs) from a copied code root, exactly as
# bin/fm-on.sh runs it on the remote host. Covers launch with the shared
# code-root credential, state, resume-in-place of a failed run, replacement
# of a missing thread, the relaunch refusal, retirement, and the credential
# link that must never destroy a real credential.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
unset FM_T3CODE_TOKEN_FILE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-t3code)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
fm_fake_exit0 "$FAKEBIN" treehouse
export PATH="$FAKEBIN:$PATH"
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"
TASK_IDS=()
cleanup() {
  local id
  for id in ${TASK_IDS[@]+"${TASK_IDS[@]}"}; do rm -rf "/tmp/fm-$id"; done
  t3_fake_stop
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup EXIT

# The remote host's code root: a copy of this branch, with its own config.
CODE_ROOT="$TMP_ROOT/remote-root"
mkdir -p "$CODE_ROOT"
(
  cd "$ROOT" || exit 1
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$CODE_ROOT" && tar -xf -)
mkdir -p "$CODE_ROOT/config"
CONTROL="$CODE_ROOT/bin/fm-remote-secondmate-control.sh"

t3_fake_start "$TMP_ROOT/server"
t3_fake_case "$TMP_ROOT/case" '{}'
t3_fake_credential "$CODE_ROOT/config/t3code-token"
ROOT_TOKEN=$(cat "$CODE_ROOT/config/t3code-token")

# A seeded remote second-mate home (the shape fm-remote-secondmate-seed.sh leaves).
make_home() { # <home> <id>
  local home=$1 id=$2
  TASK_IDS+=("$id")
  mkdir -p "$home/bin" "$home/data" "$home/config" "$home/state"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Charter\nRemote T3 second mate under test.\n' > "$home/data/charter.md"
  git -C "$home" init -q -b main
  git -C "$home" add -A
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm seed
}

control() { # <home> <verb> [args...]
  local home=$1
  shift
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 "$CONTROL" "$@" 2>&1
}

route_field() { # <route-text> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

thread_status() { # <thread> <status>
  FM_T3_THREAD=$1 FM_T3_STATUS=$2 t3_fake_set '
const t = w.threads[process.env.FM_T3_THREAD];
t.status = process.env.FM_T3_STATUS; t.activeRunId = null;
if (t.runs && t.runs[0]) { t.runs[0].status = process.env.FM_T3_STATUS; t.runs[0].completedAt = new Date().toISOString(); }'
}

HOME_A="$TMP_ROOT/home-a"
make_home "$HOME_A" rt3a

test_launch_links_shared_credential() {
  local out thread
  out=$(control "$HOME_A" launch rt3a claude claude-sonnet-5 - t3code)
  expect_code 0 $? "a remote T3 launch should succeed against the host's T3 server"$'\n'"$out"
  [ "$(route_field "$out" backend)" = t3code ] || fail "the route must name backend t3code, got: $out"
  thread=$(route_field "$out" target)
  [ -n "$thread" ] || fail "the route must carry the T3 thread id, got: $out"
  [ "$(route_field "$out" harness)" = claude ] || fail "the route must carry the harness"
  [ -L "$HOME_A/config/t3code-token" ] || fail "the home must link the code root's credential, not hold a copy"
  [ "$(cd "$(dirname "$(readlink "$HOME_A/config/t3code-token")")" && pwd -P)/t3code-token" = "$CODE_ROOT/config/t3code-token" ] \
    || fail "the home's link must point at the code root's credential, got $(readlink "$HOME_A/config/t3code-token")"
  [ -f "$CODE_ROOT/config/t3code-token" ] && [ ! -L "$CODE_ROOT/config/t3code-token" ] \
    || fail "the code root's credential must stay a real file"
  [ "$(cat "$CODE_ROOT/config/t3code-token")" = "$ROOT_TOKEN" ] || fail "the code root's credential must be unchanged"
  assert_grep "backend=t3code" "$HOME_A/state/parent-route/rt3a.meta" "the private route record must name t3code"
  [ "$(t3_fake_mutations)" = "t3_project_create t3_thread_launch t3_thread_send" ] \
    || fail "launch must create the home's project, launch one thread, and send the charter, got '$(t3_fake_mutations)'"
  RT3A_THREAD=$thread
  out=$(control "$HOME_A" state rt3a)
  [ "$(printf '%s\n' "$out" | tail -1)" = alive ] || fail "a launched T3 mate must read alive, got: $out"
  pass "remote T3 launch: one thread in the home, route reports t3code, home links the code root's credential"
}

test_alive_launch_reuses_thread() {
  local out
  : > "$T3_FAKE_LOG"
  out=$(control "$HOME_A" launch rt3a claude claude-sonnet-5 - t3code)
  expect_code 0 $? "launch on an alive T3 mate should report its route"$'\n'"$out"
  [ "$(route_field "$out" target)" = "$RT3A_THREAD" ] || fail "an alive mate must keep its thread"
  [ -z "$(t3_fake_mutations)" ] || fail "launch on an alive mate must mutate nothing, got '$(t3_fake_mutations)'"
  pass "remote T3 launch on an alive mate reuses its thread"
}

test_failed_run_resumes_in_place() {
  local out
  thread_status "$RT3A_THREAD" failed
  out=$(control "$HOME_A" state rt3a)
  [ "$(printf '%s\n' "$out" | tail -1)" = dead ] || fail "a failed T3 run must read dead, got: $out"
  : > "$T3_FAKE_LOG"
  out=$(control "$HOME_A" launch rt3a claude claude-sonnet-5 - t3code)
  expect_code 0 $? "launch on a failed T3 run should resume it"$'\n'"$out"
  [ "$(route_field "$out" target)" = "$RT3A_THREAD" ] || fail "a failed run must be resumed on the same thread, got: $out"
  [ "$(t3_fake_mutations)" = t3_thread_send ] || fail "resume must send one recovery turn and launch nothing, got '$(t3_fake_mutations)'"
  assert_contains "$(t3_fake_calls t3_thread_send)" "Firstmate recovery" "the resume turn must be the recovery message"
  pass "remote T3 failed run is resumed in place, never killed and replaced"
}

test_relaunch_is_refused() {
  local out
  out=$(control "$HOME_A" relaunch rt3a claude default default)
  expect_code 1 $? "relaunch of a T3 mate must refuse"$'\n'"$out"
  assert_contains "$out" "cannot be relaunched; retire it, then launch it again" "the refusal must say retire then launch"
  pass "remote T3 relaunch is refused with retire-then-launch guidance"
}

test_missing_thread_is_replaced() {
  local out new
  FM_T3_THREAD=$RT3A_THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_THREAD]'
  out=$(control "$HOME_A" state rt3a)
  [ "$(printf '%s\n' "$out" | tail -1)" = missing ] || fail "a thread T3 no longer has must read missing, got: $out"
  : > "$T3_FAKE_LOG"
  out=$(control "$HOME_A" launch rt3a claude claude-sonnet-5 - t3code)
  expect_code 0 $? "launch on a missing T3 thread should replace it"$'\n'"$out"
  new=$(route_field "$out" target)
  [ -n "$new" ] && [ "$new" != "$RT3A_THREAD" ] || fail "a missing thread must be replaced by a new one, got: $out"
  case " $(t3_fake_mutations) " in *" t3_thread_launch "*) ;; *) fail "replacement must launch a new thread, got '$(t3_fake_mutations)'" ;; esac
  [ "$(cat "$CODE_ROOT/config/t3code-token")" = "$ROOT_TOKEN" ] || fail "a replacement must leave the code root's credential unchanged"
  RT3A_THREAD=$new
  pass "remote T3 missing thread is replaced after its close is re-proven"
}

test_retire_archives_thread() {
  local out
  out=$(control "$HOME_A" retire rt3a --force)
  expect_code 0 $? "retire of a T3 mate should succeed"$'\n'"$out"
  [ "$(FM_T3_THREAD=$RT3A_THREAD node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const t = w.threads[process.env.FM_T3_THREAD];
process.stdout.write(String(Boolean(t && t.archived)));' "$T3_FAKE_WORLD")" = true ] || fail "retirement must archive the thread"
  [ "$(cat "$CODE_ROOT/config/t3code-token")" = "$ROOT_TOKEN" ] || fail "retirement must leave the code root's credential unchanged"
  pass "remote T3 retirement archives the thread and leaves the shared credential alone"
}

test_self_link_is_refused() {
  local home="$TMP_ROOT/home-b" out
  make_home "$home" rt3b
  cp "$CODE_ROOT/config/t3code-token" "$home/config/t3code-token"
  chmod 600 "$home/config/t3code-token"
  if out=$(FM_T3CODE_TOKEN_FILE="$home/config/t3code-token" control "$home" launch rt3b claude claude-sonnet-5 - t3code); then
    fail "a credential that resolves to the home's own file must be refused"$'\n'"$out"
  fi
  assert_contains "$out" "linking it onto itself" "the refusal must name the self-link"
  [ -f "$home/config/t3code-token" ] && [ ! -L "$home/config/t3code-token" ] || fail "the home's real credential must survive a refused self-link"
  [ "$(cat "$home/config/t3code-token")" = "$ROOT_TOKEN" ] || fail "the home's real credential must be unchanged"
  pass "remote T3 launch refuses a credential link onto itself"
}

test_real_credential_is_not_replaced() {
  local home="$TMP_ROOT/home-c" out
  make_home "$home" rt3c
  printf 'host-own-credential\n' > "$home/config/t3code-token"
  if out=$(control "$home" launch rt3c claude claude-sonnet-5 - t3code); then
    fail "a real credential file in the home must not be replaced by a link"$'\n'"$out"
  fi
  assert_contains "$out" "is a real credential file" "the refusal must name the real credential"
  [ "$(cat "$home/config/t3code-token")" = host-own-credential ] || fail "the home's own credential must be unchanged"
  pass "remote T3 launch never replaces a real credential file with a link"
}

fm_test_run \
  test_launch_links_shared_credential \
  test_alive_launch_reuses_thread \
  test_failed_run_resumes_in_place \
  test_relaunch_is_refused \
  test_missing_thread_is_replaced \
  test_retire_archives_thread \
  test_self_link_is_refused \
  test_real_credential_is_not_replaced
