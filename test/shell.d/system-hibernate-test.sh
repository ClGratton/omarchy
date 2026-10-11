#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
runtime_dir="$test_tmp/runtime"
call_log="$test_tmp/calls"
request_file="$test_tmp/requested"
marker="$runtime_dir/omarchy-hibernate-boot-auth.lock"
mkdir -p "$mock_bin" "$runtime_dir"

cat >"$mock_bin/omarchy-hibernation-boot-auth" <<'SH'
#!/bin/bash

exit "${BOOT_AUTH_STATUS:-1}"
SH

cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash

marker="$XDG_RUNTIME_DIR/omarchy-hibernate-boot-auth.lock"
marker_state=missing
if [[ -f $marker ]]; then
  exec 9<"$marker"
  flock -n -E 75 9 2>/dev/null
  lock_status=$?
  if (( lock_status == 75 )); then
    marker_state=locked
  else
    marker_state=unlocked
  fi
fi
printf 'systemctl %s marker=%s\n' "$*" "$marker_state" >>"$CALL_LOG"
touch "$REQUEST_FILE"
exit "${SYSTEMCTL_STATUS:-0}"
SH

# Stands in for logind's PrepareForSleep signals. Like logind, it emits
# PrepareForSleep(true) once the request is in and PrepareForSleep(false) only
# later, and it records whether the marker is still held in between, after
# systemctl has already returned.
cat >"$mock_bin/dbus-monitor" <<'SH'
#!/bin/bash

printf 'signal sender=org.freedesktop.DBus member=NameAcquired\n'
[[ ${SLEEP_WATCH:-} != dies ]] || exit 0

for _ in {1..200}; do
  [[ -e $REQUEST_FILE ]] && break
  sleep 0.01
done
printf '   boolean true\n'
sleep 0.2

marker="$XDG_RUNTIME_DIR/omarchy-hibernate-boot-auth.lock"
marker_state=missing
if [[ -f $marker ]]; then
  exec 9<"$marker"
  flock -n -E 75 9 2>/dev/null
  if (( $? == 75 )); then
    marker_state=locked
  else
    marker_state=unlocked
  fi
  exec 9<&-
fi
printf 'preparing marker=%s\n' "$marker_state" >>"$CALL_LOG"

printf '   boolean false\n'
exec sleep 30
SH
chmod +x "$mock_bin/omarchy-hibernation-boot-auth" "$mock_bin/systemctl" "$mock_bin/dbus-monitor"

run_hibernate() {
  : >"$call_log"
  rm -f "$request_file"
  set +e
  BOOT_AUTH_STATUS="$1" SYSTEMCTL_STATUS="${2:-0}" \
    XDG_RUNTIME_DIR="$runtime_dir" CALL_LOG="$call_log" REQUEST_FILE="$request_file" \
    PATH="$mock_bin:$PATH" \
    "$ROOT/bin/omarchy-system-hibernate"
  hibernate_status=$?
  set -e
}

run_hibernate 0
grep -Fx 'systemctl hibernate marker=locked' "$call_log" >/dev/null ||
  fail "encrypted hibernate marks boot-authenticated sleep"
pass "encrypted hibernate marks boot-authenticated sleep"

# systemctl returns as soon as logind has emitted PrepareForSleep(true), while
# the sleep monitor may still be deciding, so the marker has to outlive it.
grep -Fx 'preparing marker=locked' "$call_log" >/dev/null ||
  fail "encrypted hibernate holds its marker until PrepareForSleep(false)" "$(<"$call_log")"
pass "encrypted hibernate holds its marker until PrepareForSleep(false)"

[[ ! -e $marker ]] || fail "encrypted hibernate cleans its marker after resume"
pass "encrypted hibernate cleans its marker after resume"

# Without a working signal watch the marker goes when the request returns, as
# it did before the watch existed, instead of waiting out the timeout.
start_us=${EPOCHREALTIME//[!0-9]/}
SLEEP_WATCH=dies run_hibernate 0
elapsed_us=$((10#${EPOCHREALTIME//[!0-9]/} - 10#$start_us))
(( hibernate_status == 0 && elapsed_us < 5000000 )) ||
  fail "hibernate without a signal watch releases its marker at once" "exit: $hibernate_status, elapsed: ${elapsed_us}us"
[[ ! -e $marker ]] || fail "hibernate without a signal watch cleans its marker"
pass "hibernate without a signal watch releases its marker at once"

run_hibernate 1
grep -Fx 'systemctl hibernate marker=missing' "$call_log" >/dev/null ||
  fail "unencrypted hibernate leaves session locking enabled"
pass "unencrypted hibernate leaves session locking enabled"

run_hibernate 0 42
(( hibernate_status == 42 )) ||
  fail "hibernate propagates a failed system request" "exit: $hibernate_status"
[[ ! -e $marker ]] || fail "failed hibernate cleans its boot-auth marker"
pass "failed hibernate cleans its boot-auth marker"
