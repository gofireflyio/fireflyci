#!/bin/sh
# IaC wrapper script for capturing individual module logs when invoked by terragrunt
# This script intercepts terraform/tofu commands and ensures proper log capture per subfolder
# The IAC_BINARY environment variable determines which binary to use (terraform or tofu)
# POSIX-compliant for use in minimal containers

set -e

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

# Find the module directory where output files should be written.
# Priority: TERRAGRUNT_WORKING_DIR > FIREFLY_OUTPUT_DIR > detect from PWD
MODULE_DIR=""
if [ -n "$TERRAGRUNT_WORKING_DIR" ]; then
  MODULE_DIR="$TERRAGRUNT_WORKING_DIR"
elif [ -n "$FIREFLY_OUTPUT_DIR" ]; then
  MODULE_DIR="$FIREFLY_OUTPUT_DIR"
else
  # Detect if running inside .terragrunt-cache
  case "$PWD" in
    */.terragrunt-cache/*)
      # Walk up past .terragrunt-cache to find the module directory
      CURRENT_DIR="$PWD"
      while [ "$CURRENT_DIR" != "/" ]; do
        case "$CURRENT_DIR" in
          */.terragrunt-cache) MODULE_DIR=$(dirname "$CURRENT_DIR"); break ;;
        esac
        CURRENT_DIR=$(dirname "$CURRENT_DIR")
      done
      ;;
    *)
      # Not in .terragrunt-cache — running directly in the module directory
      if [ -f "$PWD/terragrunt.hcl" ]; then
        MODULE_DIR="$PWD"
      fi
      ;;
  esac
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
      # Use a temporary file to capture exit code (POSIX-compliant)
      EXITCODE_FILE="/tmp/wrapper_exitcode_$$"
      
      # Ensure MODULE_DIR is set and log file path is valid
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      # Run terraform and capture output, ignoring tee errors
      { "$IAC_BIN" "$@" 2>&1; echo $? > "$EXITCODE_FILE"; } | tee "$MODULE_DIR/plan_log.jsonl" || true
      EXIT_CODE=$(cat "$EXITCODE_FILE")
      rm -f "$EXITCODE_FILE"
      
      # If plan succeeded and created a plan file, generate additional outputs
      # Disable set -e for this section — terraform show failures should not crash the wrapper
      if [ $EXIT_CODE -eq 0 ]; then
        set +e
        sleep 0.1

        PLAN_FILE=""
        if [ -f "$OUT_FILE" ]; then
          PLAN_FILE="$OUT_FILE"
          # Copy plan file to module directory if not already there
          if [ "$PWD" != "$MODULE_DIR" ]; then
            cp "$OUT_FILE" "$MODULE_DIR/$OUT_FILE" 2>/dev/null
          fi
        elif [ -f "$MODULE_DIR/$OUT_FILE" ]; then
          PLAN_FILE="$MODULE_DIR/$OUT_FILE"
        fi

        if [ -n "$PLAN_FILE" ]; then
          # Generate plan_output.json (JSON format)
          TF_CLI_ARGS= "$IAC_BIN" show -json "$PLAN_FILE" > "$MODULE_DIR/plan_output.json" 2>/dev/null
          if [ $? -ne 0 ]; then
            echo "{\"error\": \"Failed to generate plan output\"}" > "$MODULE_DIR/plan_output.json"
          fi

          # Generate plan_output_raw.log (human-readable format)
          TF_CLI_ARGS= "$IAC_BIN" show "$PLAN_FILE" > "$MODULE_DIR/plan_output_raw.log" 2>/dev/null
          if [ $? -ne 0 ]; then
            echo "Failed to generate raw plan output" > "$MODULE_DIR/plan_output_raw.log"
          fi
        else
          # Plan file not found, create placeholder files
          echo "{\"error\": \"Plan file not found\"}" > "$MODULE_DIR/plan_output.json"
          echo "Plan file $OUT_FILE not found" > "$MODULE_DIR/plan_output_raw.log"
        fi
        set -e
      fi
      
      exit $EXIT_CODE
    else
      # Regular plan command
      "$IAC_BIN" "$@"
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
      # Use a temporary file to capture exit code (POSIX-compliant)
      EXITCODE_FILE="/tmp/wrapper_exitcode_$$"
      
      # Ensure MODULE_DIR is set
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      { "$IAC_BIN" "$@" 2>&1; echo $? > "$EXITCODE_FILE"; } | tee "$MODULE_DIR/apply_log.jsonl" || true
      EXIT_CODE=$(cat "$EXITCODE_FILE")
      rm -f "$EXITCODE_FILE"
      exit $EXIT_CODE
    else
      "$IAC_BIN" "$@"
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
      # Use a temporary file to capture exit code (POSIX-compliant)
      EXITCODE_FILE="/tmp/wrapper_exitcode_$$"
      
      # Ensure MODULE_DIR is set
      if [ -z "$MODULE_DIR" ]; then
        MODULE_DIR="$PWD"
      fi
      
      { "$IAC_BIN" "$@" 2>&1; echo $? > "$EXITCODE_FILE"; } | tee "$MODULE_DIR/destroy_log.jsonl" || true
      EXIT_CODE=$(cat "$EXITCODE_FILE")
      rm -f "$EXITCODE_FILE"
      exit $EXIT_CODE
    else
      "$IAC_BIN" "$@"
    fi
    ;;
    
  "init")
    # Capture init output in the module directory
    # Use a temporary file to capture exit code (POSIX-compliant)
    EXITCODE_FILE="/tmp/wrapper_exitcode_$$"
    
    # Ensure MODULE_DIR is set
    if [ -z "$MODULE_DIR" ]; then
      MODULE_DIR="$PWD"
    fi
    
    { "$IAC_BIN" "$@" 2>&1; echo $? > "$EXITCODE_FILE"; } | tee "$MODULE_DIR/init_log.jsonl" || true
    EXIT_CODE=$(cat "$EXITCODE_FILE")
    rm -f "$EXITCODE_FILE"
    exit $EXIT_CODE
    ;;
    
  "show")
    # Show command with TF_CLI_ARGS= to prevent globally set CLI arguments from affecting show
    # This matches the behavior in opentofu client.go
    TF_CLI_ARGS= "$IAC_BIN" "$@"
    ;;
    
  *)
    # For all other commands, just execute the IaC binary
    "$IAC_BIN" "$@"
    ;;
esac


