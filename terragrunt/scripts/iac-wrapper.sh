#!/bin/sh
# IaC wrapper script for capturing individual module logs when invoked by terragrunt
# This script intercepts terraform/tofu commands and ensures proper log capture per subfolder
# The IAC_BINARY environment variable determines which binary to use (terraform or tofu)
# POSIX-compliant for use in minimal containers

set -e

# Signal log file - check this to see what signals terragrunt forwards
SIGNAL_LOG="/tmp/iac_wrapper_signals.log"

# Store our PID for signal logging
WRAPPER_PID=$$

# Log signal to file
log_signal() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$WRAPPER_PID] $*" >> "$SIGNAL_LOG"
}

# Track child process PID
CHILD_PID=""

# Signal handler - logs and forwards to child
handle_signal() {
  SIGNAL_NAME="$1"
  SIGNAL_NUM="$2"
  log_signal "RECEIVED: $SIGNAL_NAME (num: $SIGNAL_NUM) - child PID: ${CHILD_PID:-none}"
  
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    log_signal "FORWARDING: $SIGNAL_NAME to PID $CHILD_PID"
    kill -"$SIGNAL_NAME" "$CHILD_PID" 2>/dev/null || log_signal "FAILED to forward $SIGNAL_NAME"
  fi
  
  exit $((128 + SIGNAL_NUM))
}

# Set up signal traps
trap 'handle_signal TERM 15' TERM
trap 'handle_signal INT 2' INT
trap 'handle_signal HUP 1' HUP

# Log startup
log_signal "STARTED: args=$*"

# Determine which binary to use from environment variable
BINARY_NAME="${IAC_BINARY:-terraform}"

# Path to the actual IaC binary
if [ -n "$IAC_BINARY_PATH" ] && [ -x "$IAC_BINARY_PATH" ]; then
  IAC_BIN="$IAC_BINARY_PATH"
elif [ -x "/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/bin/${BINARY_NAME}.real"
elif [ -x "/usr/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/usr/bin/${BINARY_NAME}.real"
elif [ -x "/usr/local/bin/${BINARY_NAME}.real" ]; then
  IAC_BIN="/usr/local/bin/${BINARY_NAME}.real"
elif [ -x "/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/bin/${BINARY_NAME}"
elif [ -x "/usr/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/usr/bin/${BINARY_NAME}"
elif [ -x "/usr/local/bin/${BINARY_NAME}" ]; then
  IAC_BIN="/usr/local/bin/${BINARY_NAME}"
else
  IAC_BIN=$(which "${BINARY_NAME}" 2>/dev/null || echo "${BINARY_NAME}")
fi

# Get the command (first argument)
COMMAND="$1"

# Filter out the standalone '-' separator that Terragrunt v0.67+ might pass
shift
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

# Rebuild positional parameters
# shellcheck disable=SC2086
set -- "$COMMAND" $NEWARGS

# Find the module directory (where terragrunt.hcl is located)
MODULE_DIR=""
if [ -n "$TERRAGRUNT_WORKING_DIR" ]; then
  MODULE_DIR="$TERRAGRUNT_WORKING_DIR"
else
  CURRENT_DIR="$PWD"
  while [ "$CURRENT_DIR" != "/" ]; do
    if [ -f "$CURRENT_DIR/../terragrunt.hcl" ]; then
      MODULE_DIR="$CURRENT_DIR/.."
      break
    fi
    CURRENT_DIR=$(dirname "$CURRENT_DIR")
  done
fi

if [ -z "$MODULE_DIR" ]; then
  MODULE_DIR="$PWD"
fi

# Execute IaC and capture logs based on the command
case "$COMMAND" in
  "plan")
    HAS_JSON=false
    OUT_FILE=""
    PREV_ARG=""
    
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
      fi
      case "$arg" in
        -out=*)
          OUT_FILE="${arg#-out=}"
          ;;
      esac
      if [ "$PREV_ARG" = "-out" ]; then
        OUT_FILE="$arg"
      fi
      PREV_ARG="$arg"
    done
    
    if [ "$HAS_JSON" = true ] && [ -n "$OUT_FILE" ]; then
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      tee "$MODULE_DIR/plan_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      CHILD_PID=$!
      
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      if [ $EXIT_CODE -eq 0 ]; then
        sleep 0.1
        
        if [ -f "$OUT_FILE" ]; then
          cp "$OUT_FILE" "$MODULE_DIR/$OUT_FILE" 2>/dev/null
          
          if TF_CLI_ARGS= "$IAC_BIN" show -json "$OUT_FILE" > "$MODULE_DIR/plan_output.json" 2>/dev/null; then
            :
          else
            TF_CLI_ARGS= "$IAC_BIN" show -json "$MODULE_DIR/$OUT_FILE" > "$MODULE_DIR/plan_output.json" 2>/dev/null || \
              echo "{\"error\": \"Failed to generate plan output\"}" > "$MODULE_DIR/plan_output.json"
          fi
          
          if ! TF_CLI_ARGS= "$IAC_BIN" show "$OUT_FILE" > "$MODULE_DIR/plan_output_raw.log" 2>/dev/null; then
            TF_CLI_ARGS= "$IAC_BIN" show "$MODULE_DIR/$OUT_FILE" > "$MODULE_DIR/plan_output_raw.log" 2>/dev/null || \
              echo "Failed to generate raw plan output" > "$MODULE_DIR/plan_output_raw.log"
          fi
        else
          echo "{\"error\": \"Plan file not found\"}" > "$MODULE_DIR/plan_output.json"
          echo "Plan file $OUT_FILE not found" > "$MODULE_DIR/plan_output_raw.log"
        fi
      fi
      
      exit $EXIT_CODE
    else
      "$IAC_BIN" "$@" &
      CHILD_PID=$!
      wait $CHILD_PID
      exit $?
    fi
    ;;
    
  "apply")
    HAS_JSON=false
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
        break
      fi
    done
    
    if [ "$HAS_JSON" = true ]; then
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      tee "$MODULE_DIR/apply_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      CHILD_PID=$!
      
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      exit $EXIT_CODE
    else
      "$IAC_BIN" "$@" &
      CHILD_PID=$!
      wait $CHILD_PID
      exit $?
    fi
    ;;
    
  "destroy")
    HAS_JSON=false
    for arg in "$@"; do
      if [ "$arg" = "-json" ]; then
        HAS_JSON=true
        break
      fi
    done
    
    if [ "$HAS_JSON" = true ]; then
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      FIFO="/tmp/wrapper_fifo_$$"
      mkfifo "$FIFO" 2>/dev/null || true
      
      tee "$MODULE_DIR/destroy_log.jsonl" < "$FIFO" &
      TEE_PID=$!
      
      "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
      CHILD_PID=$!
      
      wait $CHILD_PID 2>/dev/null
      EXIT_CODE=$?
      
      wait $TEE_PID 2>/dev/null || true
      rm -f "$FIFO"
      
      exit $EXIT_CODE
    else
      "$IAC_BIN" "$@" &
      CHILD_PID=$!
      wait $CHILD_PID
      exit $?
    fi
    ;;
    
  "init")
    if [ -z "$MODULE_DIR" ]; then
      MODULE_DIR="$PWD"
    fi
    
    FIFO="/tmp/wrapper_fifo_$$"
    mkfifo "$FIFO" 2>/dev/null || true
    
    tee "$MODULE_DIR/init_log.jsonl" < "$FIFO" &
    TEE_PID=$!
    
    "$IAC_BIN" "$@" > "$FIFO" 2>&1 &
    CHILD_PID=$!
    
    wait $CHILD_PID 2>/dev/null
    EXIT_CODE=$?
    
    wait $TEE_PID 2>/dev/null || true
    rm -f "$FIFO"
    
    exit $EXIT_CODE
    ;;
    
  "show")
    TF_CLI_ARGS= "$IAC_BIN" "$@" &
    CHILD_PID=$!
    wait $CHILD_PID
    exit $?
    ;;
    
  *)
    "$IAC_BIN" "$@" &
    CHILD_PID=$!
    wait $CHILD_PID
    exit $?
    ;;
esac
