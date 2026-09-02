#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const lockQml = fs.readFileSync(`${root}/shell/plugins/lock/Service.qml`, 'utf8')
const sleepLock = fs.readFileSync(`${root}/bin/omarchy-system-sleep-lock`, 'utf8')
const sleepMonitor = fs.readFileSync(`${root}/bin/omarchy-system-sleep-monitor`, 'utf8')

assert(
  /lock_ipc "\$lock_timeout_ms" lock lockForSleep/.test(sleepLock),
  'the sleep inhibitor selects the sleep-specific concealed lock path'
)
assert(
  /function beginSleepLock\(\)[\s\S]*sleepTransitionConcealed = true[\s\S]*beginLock\(\)/.test(lockQml),
  'sleep concealment is active before ext-session-lock begins'
)
assert(
  /function resumeFromSleep\(\): string[\s\S]*sleepTransitionConcealed[\s\S]*root\.runWake\("resume-signal"\)[\s\S]*root\.lockRequested[\s\S]*root\.beginPasswordFocusRecovery\(true\)/.test(lockQml)
    && /lock resumeFromSleep/.test(sleepMonitor),
  'one shared post-resume event releases concealment and restores password focus'
)
assert(
  /function handlePointerWake\(\)[\s\S]*sleepTransitionConcealed && !root\.sleepTransitionPointerArmed[\s\S]*runWake\(\)/.test(lockQml)
    && /onWakeRequested: root\.runWake\(\)/.test(lockQml),
  'keyboard and settled pointer activity remain in-shell escape paths'
)
assert(
  /PreparingForSleep/.test(sleepMonitor)
    && /preparing_for_sleep[\s\S]*state=\$\?/.test(sleepMonitor)
    && /Never report resume from an unknown logind state/.test(sleepMonitor),
  'the external monitor waits for a known post-resume state before notification'
)
assert(
  /function beginSleepLock\(\)[\s\S]*if \(root\.locked\) \{[\s\S]*idleBlankTimer\.stop\(\)[\s\S]*if \(beginLock\(\)\) \{[\s\S]*idleBlankTimer\.stop\(\)/.test(lockQml)
    && !/lockForSleep[\s\S]{0,1200}(runBlank|brightness-display off)/.test(lockQml + sleepLock),
  'the sleep path suppresses the ordinary blank timer and never requests pre-sleep DPMS-off'
)
JS
