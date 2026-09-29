#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
fixture_dir="$ROOT/test/shell.d/fixtures/audio-output-profiles"
export CARDS_FIXTURE="$test_tmp/cards.json"
export ROUTES_FIXTURE="$test_tmp/routes.json"
export CALL_LOG="$test_tmp/calls"
export POLL_COUNT="$test_tmp/polls"
cp "$fixture_dir/laptop-cards.json" "$CARDS_FIXTURE"
cp "$fixture_dir/laptop-routes.json" "$ROUTES_FIXTURE"

cat >"$stub_bin/pw-dump" <<'SH'
#!/bin/bash
cat "$ROUTES_FIXTURE"
SH

cat >"$stub_bin/pactl" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ $* == "-f json list cards" ]]; then
  cat "$CARDS_FIXTURE"
elif [[ $1 == "set-card-profile" ]]; then
  printf 'profile\t%s\t%s\n' "$2" "$3" >>"$CALL_LOG"
  [[ ${FAIL_ACTIVATE:-0} == "0" ]]
elif [[ $* == "-f json list sinks" ]]; then
  count=$(cat "$POLL_COUNT" 2>/dev/null || echo 0)
  echo "$((count + 1))" >"$POLL_COUNT"
  if (( count < ${DELAY_POLLS:-0} )) || [[ ${NO_SINK:-0} == "1" ]]; then
    echo '[]'
  else
    jq -nc --arg available "${SINK_AVAILABLE:-available}" '[{
      index: 432, name: "alsa_output.pch.hdmi-stereo",
      properties: {"device.name": "alsa_card.pch", "device.profile.name": "hdmi-stereo", "object.id": "62"},
      ports: [{name: "hdmi-output-0", availability: $available}]
    }]'
  fi
elif [[ $1 == "get-default-sink" ]]; then
  echo "${DEFAULT_SINK:-alsa_output.pch.hdmi-stereo}"
else
  exit 1
fi
SH

cat >"$stub_bin/omarchy-audio-output-set-default" <<'SH'
#!/bin/bash
printf 'default\t%s\t%s\n' "$1" "$2" >>"$CALL_LOG"
SH
chmod +x "$stub_bin"/*
export PATH="$stub_bin:$ROOT/bin:$PATH"

profiles=$(omarchy-audio-output-profiles)
if jq -e 'length == 2
  and any(.[]; .label == "Speakers" and .profileName == "output:analog-stereo+input:analog-stereo")
  and any(.[]; .label == "Panasonic-TV" and .profileName == "output:hdmi-stereo+input:analog-stereo")' <<<"$profiles" >/dev/null; then
  pass "duplex rows use playback labels, prefer speakers, and exclude unavailable profiles"
else
  fail "duplex rows use playback labels, prefer speakers, and exclude unavailable profiles" "$profiles"
fi

# Keep the active microphone mapping even when an output-only profile has a
# higher priority. Preserve a deliberately output-only setup as well.
jq '.[0].profiles["output:hdmi-stereo"].priority = 20000' "$CARDS_FIXTURE" >"$test_tmp/changed.json"
mv "$test_tmp/changed.json" "$CARDS_FIXTURE"
if omarchy-audio-output-profiles | jq -e 'any(.[]; .profileName == "output:hdmi-stereo+input:analog-stereo")' >/dev/null; then
  pass "output choice retains the current microphone mapping ahead of priority"
else
  fail "output choice retains the current microphone mapping ahead of priority"
fi
jq '.[0].active_profile = "output:analog-stereo"' "$CARDS_FIXTURE" >"$test_tmp/changed.json"
mv "$test_tmp/changed.json" "$CARDS_FIXTURE"
if omarchy-audio-output-profiles | jq -e 'all(.[]; .profileName | contains("+input:") | not)' >/dev/null; then
  pass "output choice preserves an output-only profile"
else
  fail "output choice preserves an output-only profile"
fi
cp "$fixture_dir/laptop-cards.json" "$CARDS_FIXTURE"

profile="output:hdmi-stereo+input:analog-stereo"
DELAY_POLLS=2 omarchy-audio-output-set-profile alsa_card.pch "$profile"
if rg -F $'profile\talsa_card.pch\toutput:hdmi-stereo+input:analog-stereo' "$CALL_LOG" >/dev/null &&
  rg -F $'default\t62\talsa_output.pch.hdmi-stereo' "$CALL_LOG" >/dev/null &&
  (( $(cat "$POLL_COUNT") >= 3 )); then
  pass "duplex selection waits for its sink, retains capture, and passes the PipeWire id"
else
  fail "duplex selection waits for its sink, retains capture, and passes the PipeWire id"
fi

expect_failure() {
  local description=$1
  shift
  : >"$CALL_LOG"
  if "$@" >"$test_tmp/stdout" 2>"$test_tmp/stderr"; then
    fail "$description"
  else
    pass "$description"
  fi
}

expect_failure "explicitly unavailable profiles cannot be activated" omarchy-audio-output-set-profile alsa_card.pch output:hdmi-stereo-extra1
[[ ! -s $CALL_LOG ]] || fail "unavailable profiles do not mutate the card"

jq '.[0].info.params.EnumRoute |= map(if .name == "hdmi-output-0" then .available = "no" else . end)' "$ROUTES_FIXTURE" >"$test_tmp/changed.json"
mv "$test_tmp/changed.json" "$ROUTES_FIXTURE"
expect_failure "a monitor disconnected since the menu refresh is rejected" omarchy-audio-output-set-profile alsa_card.pch "$profile"
[[ ! -s $CALL_LOG ]] || fail "disconnected monitor does not change the profile"
cp "$fixture_dir/laptop-routes.json" "$ROUTES_FIXTURE"

expect_failure "profile activation failure is propagated" env FAIL_ACTIVATE=1 omarchy-audio-output-set-profile alsa_card.pch "$profile"
if rg '^default' "$CALL_LOG" >/dev/null; then fail "failed activation never changes the default"; fi

expect_failure "a missing sink times out" env NO_SINK=1 omarchy-audio-output-set-profile alsa_card.pch "$profile"
if rg '^default' "$CALL_LOG" >/dev/null; then fail "missing sink never changes the default"; fi

expect_failure "disconnect during activation does not select an unavailable sink" env SINK_AVAILABLE='not available' omarchy-audio-output-set-profile alsa_card.pch "$profile"
if rg '^default' "$CALL_LOG" >/dev/null; then fail "unavailable sink never changes the default"; fi

expect_failure "a failed default-output change is reported" env DEFAULT_SINK=alsa_output.other omarchy-audio-output-set-profile alsa_card.pch "$profile"
