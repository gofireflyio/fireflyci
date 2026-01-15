#!/bin/sh
# IaC wrapper script for capturing individual module logs when invoked by terragrunt
# This script intercepts terraform/tofu commands and ensures proper log capture per subfolder
# The IAC_BINARY environment variable determines which binary to use (terraform or tofu)
# POSIX-compliant for use in minimal containers
#
# SIGNAL HANDLING NOTE:
# GitHub Actions sends SIGINT, then SIGTERM after 7.5s, then SIGKILL after 10s total.
# Terragrunt has a 15-second SignalForwardingDelay before forwarding signals to children.
# This means terraform never receives forwarded signals before SIGKILL!
# Our wrapper traps signals and forwards them IMMEDIATELY to terraform.

set -e

# Enable Terraform/OpenTofu debug logging for signal handling investigation
export TF_LOG="${TF_LOG:-DEBUG}"
export TF_LOG_PATH="${TF_LOG_PATH:-/tmp/terraform_debug_$$.log}"

# Store our PID and process info for debugging
WRAPPER_PID=$$
WRAPPER_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo "unknown")

# Debug logging function
debug_log() {
  echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S.%N' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')] [PID:$WRAPPER_PID PGID:$WRAPPER_PGID] $*" >&2
}

# Log startup info
debug_log "=== IAC WRAPPER STARTED ==="
debug_log "Script PID: $WRAPPER_PID, PGID: $WRAPPER_PGID"
debug_log "Parent PID (PPID): $PPID"
debug_log "TF_LOG=$TF_LOG, TF_LOG_PATH=$TF_LOG_PATH"
debug_log "Arguments: $*"

# Track child process PID (the actual terraform process)
CHILD_PID=""
# File to communicate terraform PID from subshell
TF_PID_FILE="/tmp/wrapper_tf_pid_$$"

# Signal handler function with detailed logging
handle_signal() {
  SIGNAL_NAME="$1"
  SIGNAL_NUM="$2"
  debug_log "!!! RECEIVED SIGNAL: $SIGNAL_NAME (num: $SIGNAL_NUM) !!!"
  debug_log "Current CHILD_PID: ${CHILD_PID:-not set}"
  
  # Try to read the actual terraform PID from the file (in case subshell wrote it)
  if [ -f "$TF_PID_FILE" ]; then
    ACTUAL_TF_PID=$(cat "$TF_PID_FILE" 2>/dev/null || echo "")
    debug_log "Read terraform PID from file: ${ACTUAL_TF_PID:-empty}"
    if [ -n "$ACTUAL_TF_PID" ] && [ "$ACTUAL_TF_PID" != "$CHILD_PID" ]; then
      debug_log "Using actual terraform PID $ACTUAL_TF_PID instead of subshell PID $CHILD_PID"
      CHILD_PID="$ACTUAL_TF_PID"
    fi
  fi
  
  # Log process tree for debugging
  debug_log "Process tree at signal receipt:"
  ps -ef 2>/dev/null | grep -E "($$|terraform|tofu|terragrunt)" | head -20 >&2 || true
  
  # If we have a child process, forward the signal to it
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    debug_log "Forwarding $SIGNAL_NAME to child process $CHILD_PID"
    kill -"$SIGNAL_NAME" "$CHILD_PID" 2>/dev/null || debug_log "Failed to send $SIGNAL_NAME to $CHILD_PID"
    
    # Give terraform time to release locks gracefully
    debug_log "Waiting up to 30s for child $CHILD_PID to terminate gracefully..."
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 30 ] && kill -0 "$CHILD_PID" 2>/dev/null; do
      sleep 1
      WAIT_COUNT=$((WAIT_COUNT + 1))
      debug_log "Still waiting for child $CHILD_PID... ($WAIT_COUNT/30s)"
    done
    
    if kill -0 "$CHILD_PID" 2>/dev/null; then
      debug_log "Child $CHILD_PID still running after 30s, sending KILL"
      kill -KILL "$CHILD_PID" 2>/dev/null || true
    else
      debug_log "Child $CHILD_PID terminated gracefully"
    fi
  else
    debug_log "No child process to forward signal to, trying process group kill"
    # Try to kill process group
    kill -"$SIGNAL_NAME" -$$ 2>/dev/null || kill -"$SIGNAL_NAME" 0 2>/dev/null || true
  fi
  
  debug_log "Signal handler complete for $SIGNAL_NAME, exiting with code 128+$SIGNAL_NUM"
  rm -f "$TF_PID_FILE"
  exit $((128 + SIGNAL_NUM))
}

# Set up signal traps with logging
trap 'handle_signal TERM 15' TERM
trap 'handle_signal INT 2' INT
trap 'handle_signal HUP 1' HUP
trap 'handle_signal QUIT 3' QUIT
trap 'handle_signal USR1 10' USR1
trap 'handle_signal USR2 12' USR2
trap 'handle_signal PIPE 13' PIPE
trap 'handle_signal ALRM 14' ALRM
trap 'handle_signal ABRT 6' ABRT

# Also log on EXIT for debugging
trap 'debug_log "EXIT trap triggered, exit code: $?"; rm -f "$TF_PID_FILE"' EXIT

debug_log "Signal traps configured for: TERM INT HUP QUIT USR1 USR2 PIPE ALRM ABRT EXIT"

# Check if setsid with -w (wait) flag is available
# The -w flag makes setsid wait for the child to exit, which is critical
# Without -w, setsid exits immediately and we lose track of terraform
HAVE_SETSID_WAIT=""
if command -v setsid >/dev/null 2>&1; then
  # Test if -w flag is supported (Linux setsid supports it, BSD may not)
  if setsid -w true >/dev/null 2>&1; then
    HAVE_SETSID_WAIT="yes"
    debug_log "setsid -w is available - will use it to isolate terraform process"
  else
    debug_log "setsid available but -w flag not supported - will NOT use setsid"
  fi
else
  debug_log "setsid NOT available - signals may go directly to terraform"
fi

# Helper function to run terraform with proper signal propagation
# Uses setsid -w (if available) to put terraform in a new session so signals
# sent to our process group come to our wrapper, not terraform directly
# IMPORTANT: Must use -w flag so setsid waits for the child process!
run_terraform_bg() {
  if [ -n "$HAVE_SETSID_WAIT" ]; then
    # setsid -w runs the command in a new session AND waits for it
    setsid -w "$@" &
  else
    "$@" &
  fi
  CHILD_PID=$!
  echo "$CHILD_PID" > "$TF_PID_FILE"
  debug_log "Started terraform with PID: $CHILD_PID (saved to $TF_PID_FILE) [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
  
  # Wait for it to complete
  wait $CHILD_PID 2>/dev/null
  TF_EXIT=$?
  rm -f "$TF_PID_FILE"
  return $TF_EXIT
}

# Determine which binary to use from environment variable
BINARY_NAME="${IAC_BINARY:-terraform}"  # Default to terraform if not set

# Path to the actual IaC binary
# First check if IAC_BINARY_PATH is set (used when wrapper is installed)
if [ -n "$IAC_BINARY_PATH" ] && [ -x "$IAC_BINARY_PATH" ]; then
  IAC_BIN="$IAC_BINARY_PATH"
# Otherwise try to find the .real version (in case wrapper was installed)
elif [ -x "/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/bin/${BINARY_NAME}.real"
elif [ -x "/usr/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/usr/bin/${BINARY_NAME}.real"
elif [ -x "/usr/local/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/usr/local/bin/${BINARY_NAME}.real"
# Fall back to finding the regular binary
elif [ -x "/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/bin/${BINARY_NAME}"
elif [ -x "/usr/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/usr/bin/${BINARY_NAME}"
elif [ -x "/usr/local/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/usr/local/bin/${BINARY_NAME}"
else
  # Try to find it using which
  IAC_BIN=$(which "${BINARY_NAME}" 2>/dev/null || echo "${BINARY_NAME}")
fi

# Get the command (first argument)
COMMAND="$1"

# Filter out the standalone '-' separator that Terragrunt v0.67+ might pass
# This is used by Terragrunt to separate its flags from Terraform flags
# We need to rebuild the argument list without the '-' separator
# Use a POSIX-compliant approach with positional parameters
shift # Remove the command from $@
NEWARGS=""
FIRST=1
for arg in "$@"; do
  if [ "$arg" != "-" ]; then
    if [ "$FIRST" -eq 1 ]; then
      NEWARGS="$arg"
      FIRST=0
    else
      NEWARGS="$NEWARGS $arg"
    fi
  fi
done

# Rebuild positional parameters with command + filtered args
# shellcheck disable=SC2086
set -- "$COMMAND" $NEWARGS

# Find the module directory (where terragrunt.hcl is located)
# Terragrunt runs IaC from .terragrunt-cache, but we want logs in the module dir
MODULE_DIR=""
if [ -n "$TERRAGRUNT_WORKING_DIR" ]; then
  MODULE_DIR="$TERRAGRUNT_WORKING_DIR"
else
  # Try to find the parent directory that contains terragrunt.hcl
  CURRENT_DIR="$PWD"
  while [ "$CURRENT_DIR" != "/" ]; do
    if [ -f "$CURRENT_DIR/../terragrunt.hcl" ]; then
      MODULE_DIR="$CURRENT_DIR/.."
      break
    fi
    CURRENT_DIR=$(dirname "$CURRENT_DIR")
  done
fi

# If we couldn't find module dir, use current directory
if [ -z "$MODULE_DIR" ]; then
  MODULE_DIR="$PWD"
fi

# Execute IaC and capture logs based on the command
case "$COMMAND" in
  "plan")
    # Check if -json flag is present and -out flag is present
    HAS_JSON=false
    OUT_FILE=""
    PREV_ARG=""
    
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
      fi
      # Handle -out=filename format
      case "$arg" in
        -out=*)
          OUT_FILE="${arg#-out=}"
          ;;
      esac
      # Handle -out filename format (filename is in next arg)
      if [ "$PREV_ARG" = "-out" ]; then
        OUT_FILE="$arg"
      fi
      PREV_ARG="$arg"
    done
    
    # If this is a plan with -json and -out, capture to plan_log.jsonl
    if [ "$HAS_JSON" = true ] && [ -n "$OUT_FILE" ]; then
      # Run plan and redirect output to plan_log.jsonl in the module directory
      # Ensure MODULE_DIR is set and log file path is valid
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      debug_log "Starting plan command with JSON output capture"
      debug_log "Command: $IAC_BIN $*"
      
      # Run terraform in background to allow signal handling
      # Create a named pipe for output capture
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      # Start tee in background reading from fifo
      tee "$MODULE_DIR/plan_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      # Run terraform with output to fifo
      # Use setsid -w (if available) to isolate terraform from our process group
      # The -w flag is critical - it makes setsid wait for the child process
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      else
        "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform plan started with PID: $CHILD_PID (tee PID: $TEE_PID) [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      debug_log "Terraform PID written to: $TF_PID_FILE"
      
      # Wait for terraform to complete
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      debug_log "Terraform process $CHILD_PID exited with code: $EXIT_CODE"
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      debug_log "Plan command completed with exit code: $EXIT_CODE"
      
      # If plan succeeded and created a plan file, generate additional outputs
      # The plan file is in the current working directory (.terragrunt-cache)
      if [ $EXIT_CODE -eq 0 ]; then
        # Wait a moment for file system sync
        sleep 0.1
        
        if [ -f "$OUT_FILE" ]; then
          # Copy plan file to module directory
          cp "$OUT_FILE" "$MODULE_DIR/$OUT_FILE" 2>/dev/null
          
          # Generate plan_output.json (JSON format) - critical file
          # Use TF_CLI_ARGS= to prevent globally set CLI arguments from affecting show
          if TF_CLI_ARGS= "$IAC_BIN" show -json "$OUT_FILE" > "$MODULE_DIR/plan_output.json" 2>/dev/null; then
            : # Success
          else
            # If show fails, try with the copied plan file
            TF_CLI_ARGS= "$IAC_BIN" show -json "$MODULE_DIR/$OUT_FILE" > "$MODULE_DIR/plan_output.json" 2>/dev/null || \
              echo "{\"error\": \"Failed to generate plan output\"}" > "$MODULE_DIR/plan_output.json"
          fi
          
          # Generate plan_output_raw.log (human-readable format)
          # Use TF_CLI_ARGS= to prevent globally set CLI arguments from affecting show
          if ! TF_CLI_ARGS= "$IAC_BIN" show "$OUT_FILE" > "$MODULE_DIR/plan_output_raw.log" 2>/dev/null; then
            TF_CLI_ARGS= "$IAC_BIN" show "$MODULE_DIR/$OUT_FILE" > "$MODULE_DIR/plan_output_raw.log" 2>/dev/null || \
              echo "Failed to generate raw plan output" > "$MODULE_DIR/plan_output_raw.log"
          fi
        else
          # Plan file not found, create placeholder files
          echo "{\"error\": \"Plan file not found\"}" > "$MODULE_DIR/plan_output.json"
          echo "Plan file $OUT_FILE not found" > "$MODULE_DIR/plan_output_raw.log"
        fi
      fi
      
      exit $EXIT_CODE
    else
      # Regular plan command - run in background for signal handling
      debug_log "Starting regular plan command: $IAC_BIN $*"
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" &
      else
        "$IAC_BIN" "$@" &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform plan started with PID: $CHILD_PID [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      wait $CHILD_PID
      EXIT_CODE=$?
      debug_log "Plan completed with exit code: $EXIT_CODE"
      exit $EXIT_CODE
    fi
    ;;
    
  "apply")
    # Check if -json flag is present
    HAS_JSON=false
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
        break
      fi
    done
    
    if [ "$HAS_JSON" = true ]; then
      # Capture JSON output to apply_log.jsonl in the module directory
      # Ensure MODULE_DIR is set
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      debug_log "Starting apply command with JSON output capture"
      debug_log "Command: $IAC_BIN $*"
      
      # Run terraform in background to allow signal handling
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      tee "$MODULE_DIR/apply_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      # Run terraform using setsid -w to isolate from our process group
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      else
        "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform apply started with PID: $CHILD_PID (tee PID: $TEE_PID) [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      debug_log "Terraform PID written to: $TF_PID_FILE"
      
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      debug_log "Terraform process $CHILD_PID exited with code: $EXIT_CODE"
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      debug_log "Apply command completed with exit code: $EXIT_CODE"
      exit $EXIT_CODE
    else
      # Regular apply command - run in background for signal handling
      debug_log "Starting regular apply command: $IAC_BIN $*"
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" &
      else
        "$IAC_BIN" "$@" &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform apply started with PID: $CHILD_PID [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      wait $CHILD_PID
      EXIT_CODE=$?
      debug_log "Apply completed with exit code: $EXIT_CODE"
      exit $EXIT_CODE
    fi
    ;;
    
  "destroy")
    # Check if -json flag is present
    HAS_JSON=false
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
        break
      fi
    done
    
    if [ "$HAS_JSON" = true ]; then
      # Capture JSON output to destroy_log.jsonl in the module directory
      # Ensure MODULE_DIR is set
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      debug_log "Starting destroy command with JSON output capture"
      debug_log "Command: $IAC_BIN $*"
      
      # Run terraform in background to allow signal handling
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      tee "$MODULE_DIR/destroy_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      # Run terraform using setsid -w to isolate from our process group
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      else
        "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform destroy started with PID: $CHILD_PID (tee PID: $TEE_PID) [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      debug_log "Terraform PID written to: $TF_PID_FILE"
      
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      debug_log "Terraform process $CHILD_PID exited with code: $EXIT_CODE"
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      debug_log "Destroy command completed with exit code: $EXIT_CODE"
      exit $EXIT_CODE
    else
      # Regular destroy command - run in background for signal handling
      debug_log "Starting regular destroy command: $IAC_BIN $*"
      if [ -n "$HAVE_SETSID_WAIT" ]; then
        setsid -w "$IAC_BIN" "$@" &
      else
        "$IAC_BIN" "$@" &
      fi
      CHILD_PID=$!
      echo "$CHILD_PID" > "$TF_PID_FILE"
      debug_log "Terraform destroy started with PID: $CHILD_PID [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
      wait $CHILD_PID
      EXIT_CODE=$?
      debug_log "Destroy completed with exit code: $EXIT_CODE"
      exit $EXIT_CODE
    fi
    ;;
    
  "init")
    # Capture init output in the module directory
    # Ensure MODULE_DIR is set
    if [ -z "$MODULE_DIR" ]; then
      MODULE_DIR="$PWD"
    fi
    
    debug_log "Starting init command with output capture"
    debug_log "Command: $IAC_BIN $*"
    
    # Run terraform in background to allow signal handling
    FIFO="/tmp/wrapper_fifo_$$"
    mkfifo "$FIFO" 2>/dev/null || true
    
    tee "$MODULE_DIR/init_log.jsonl" < "$FIFO" &
    TEE_PID=$!
    
    # Run terraform using setsid -w to isolate from our process group
    if [ -n "$HAVE_SETSID_WAIT" ]; then
      setsid -w "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
    else
      "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
    fi
    CHILD_PID=$!
    echo "$CHILD_PID" > "$TF_PID_FILE"
    debug_log "Terraform init started with PID: $CHILD_PID (tee PID: $TEE_PID) [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
    debug_log "Terraform PID written to: $TF_PID_FILE"
    
    wait $CHILD_PID 2>/dev/null
    EXIT_CODE=$?
    debug_log "Terraform process $CHILD_PID exited with code: $EXIT_CODE"
    
    wait $TEE_PID 2>/dev/null || true
    rm -f "$FIFO"
    
    debug_log "Init command completed with exit code: $EXIT_CODE"
    exit $EXIT_CODE
    ;;
    
  "show")
    # Show command with TF_CLI_ARGS= to prevent globally set CLI arguments from affecting show
    # This matches the behavior in opentofu client.go
    debug_log "Starting show command: $IAC_BIN $*"
    if [ -n "$HAVE_SETSID_WAIT" ]; then
      TF_CLI_ARGS= setsid -w "$IAC_BIN" "$@" &
    else
      TF_CLI_ARGS= "$IAC_BIN" "$@" &
    fi
    CHILD_PID=$!
    echo "$CHILD_PID" > "$TF_PID_FILE"
    debug_log "Terraform show started with PID: $CHILD_PID [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
    wait $CHILD_PID
    EXIT_CODE=$?
    debug_log "Show completed with exit code: $EXIT_CODE"
    exit $EXIT_CODE
    ;;
    
  *)
    # For all other commands, run in background for signal handling
    debug_log "Starting command '$COMMAND': $IAC_BIN $*"
    if [ -n "$HAVE_SETSID_WAIT" ]; then
      setsid -w "$IAC_BIN" "$@" &
    else
      "$IAC_BIN" "$@" &
    fi
    CHILD_PID=$!
    echo "$CHILD_PID" > "$TF_PID_FILE"
    debug_log "Terraform $COMMAND started with PID: $CHILD_PID [setsid -w: ${HAVE_SETSID_WAIT:-no}]"
    wait $CHILD_PID
    EXIT_CODE=$?
    debug_log "Command '$COMMAND' completed with exit code: $EXIT_CODE"
    exit $EXIT_CODE
    ;;
esac


