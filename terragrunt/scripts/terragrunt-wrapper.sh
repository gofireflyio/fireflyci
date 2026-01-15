#!/bin/sh
# Terragrunt wrapper script for debugging signal handling in GitHub Actions
#
# PROBLEM:
# - GitHub Actions sends SIGINT, then SIGTERM after 7.5s, then SIGKILL after 10s total
# - Terragrunt has a 15-second SignalForwardingDelay before forwarding signals to children
# - This means terraform never receives forwarded signals before SIGKILL!
#
# SOLUTION:
# This wrapper:
# 1. Logs all signals received (to debug what GitHub actually sends)
# 2. Immediately forwards signals to Terragrunt (bypassing the 15s delay issue)
# 3. Gives terragrunt time to forward to terraform before we exit
#
# USAGE:
#   terragrunt-wrapper.sh run-all apply --terragrunt-non-interactive -- -auto-approve -json

# Enable debug output
WRAPPER_PID=$$
SIGNAL_LOG="/tmp/signal_debug_$$.log"

log_msg() {
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%N' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
  echo "[$TIMESTAMP] [TGWRAPPER PID:$WRAPPER_PID] $*" | tee -a "$SIGNAL_LOG" >&2
}

log_msg "=== TERRAGRUNT WRAPPER STARTED ==="
log_msg "Arguments: $*"
log_msg "Signal log: $SIGNAL_LOG"

# Track terragrunt PID
TG_PID=""

# Signal handler - logs and forwards immediately
handle_signal() {
  SIGNAL_NAME="$1"
  SIGNAL_NUM="$2"
  
  log_msg "!!! RECEIVED SIGNAL: $SIGNAL_NAME (num: $SIGNAL_NUM) !!!"
  log_msg "Terragrunt PID: ${TG_PID:-not started}"
  
  # Log process tree
  log_msg "Process tree:"
  ps -ef 2>/dev/null | grep -E "(terragrunt|terraform|tofu|$$)" | head -30 >> "$SIGNAL_LOG" 2>&1 || true
  
  if [ -n "$TG_PID" ] && kill -0 "$TG_PID" 2>/dev/null; then
    log_msg "Forwarding $SIGNAL_NAME to terragrunt PID $TG_PID IMMEDIATELY"
    
    # Forward signal to terragrunt
    kill -"$SIGNAL_NAME" "$TG_PID" 2>/dev/null || log_msg "Failed to send $SIGNAL_NAME to $TG_PID"
    
    # Also try to forward to terragrunt's process group
    kill -"$SIGNAL_NAME" -"$TG_PID" 2>/dev/null || true
    
    # Wait for terragrunt to handle the signal (give it time to forward to terraform)
    log_msg "Waiting for terragrunt to handle signal and forward to terraform..."
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 8 ] && kill -0 "$TG_PID" 2>/dev/null; do
      sleep 1
      WAIT_COUNT=$((WAIT_COUNT + 1))
      log_msg "Waiting... ($WAIT_COUNT/8s)"
    done
    
    if kill -0 "$TG_PID" 2>/dev/null; then
      log_msg "Terragrunt still running after 8s, sending TERM"
      kill -TERM "$TG_PID" 2>/dev/null || true
      sleep 1
      if kill -0 "$TG_PID" 2>/dev/null; then
        log_msg "Terragrunt still running, sending KILL"
        kill -KILL "$TG_PID" 2>/dev/null || true
      fi
    fi
  else
    log_msg "No terragrunt process to forward signal to"
  fi
  
  log_msg "Signal handler complete, exiting with code $((128 + SIGNAL_NUM))"
  exit $((128 + SIGNAL_NUM))
}

# Set up signal traps
trap 'handle_signal INT 2' INT
trap 'handle_signal TERM 15' TERM
trap 'handle_signal HUP 1' HUP
trap 'handle_signal QUIT 3' QUIT

# Log on exit
trap 'log_msg "EXIT trap triggered, exit code: $?"' EXIT

log_msg "Signal traps configured for: INT TERM HUP QUIT EXIT"

# Find terragrunt binary - prefer TERRAGRUNT_REAL_PATH if set (when installed as wrapper)
if [ -n "$TERRAGRUNT_REAL_PATH" ] && [ -x "$TERRAGRUNT_REAL_PATH" ]; then
  TERRAGRUNT_BIN="$TERRAGRUNT_REAL_PATH"
  log_msg "Using real terragrunt from TERRAGRUNT_REAL_PATH: $TERRAGRUNT_BIN"
elif [ -x "/usr/local/bin/terragrunt.real" ]; then
  TERRAGRUNT_BIN="/usr/local/bin/terragrunt.real"
  log_msg "Using real terragrunt: $TERRAGRUNT_BIN"
else
  TERRAGRUNT_BIN=$(command -v terragrunt.real 2>/dev/null || command -v terragrunt 2>/dev/null || echo "terragrunt")
  log_msg "Using terragrunt: $TERRAGRUNT_BIN"
fi

# Run terragrunt in background so we can trap signals
log_msg "Starting terragrunt: $TERRAGRUNT_BIN $*"
"$TERRAGRUNT_BIN" "$@" &
TG_PID=$!
log_msg "Terragrunt started with PID: $TG_PID"

# Wait for terragrunt to complete
wait $TG_PID 2>/dev/null
EXIT_CODE=$?
log_msg "Terragrunt exited with code: $EXIT_CODE"

exit $EXIT_CODE
