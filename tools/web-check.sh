#!/usr/bin/env bash
set -euo pipefail

# Defaults
EXPECTED_STATUS=200
RETRY_DELAY=5
REQUIRED_TEXT=""
URL=""
MAX_ATTEMPTS=0   # 0 = retry forever

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0") -u <url> [-s <expected_status>] [-t <required_text>] [-d <retry_delay_seconds>] [-m <max_attempts>]

Options:
  -u  Target URL to query (required)
  -s  Expected HTTP status code (default: 200)
  -t  Optional text that must appear in the response body
  -d  Delay between retries in seconds (default: 5)
  -m  Maximum number of attempts before giving up (default: 0 = infinite)
  -h  Show this help

Behavior:
  - Follows redirects
  - Accepts untrusted/invalid TLS certificates
  - On failure, prints the last HTTP status and retries after the configured delay
  - Intermediate failures update on a single line (TTY); non-TTY prints one line per attempt
  - Exits 0 on success; non-zero on failure if max attempts is reached
  - Prints final statistics (attempts, retries, total runtime)
EOF
}

# Parse arguments
while getopts ":u:s:t:d:m:h" opt; do
  case "$opt" in
    u) URL="$OPTARG" ;;
    s) EXPECTED_STATUS="$OPTARG" ;;
    t) REQUIRED_TEXT="$OPTARG" ;;
    d) RETRY_DELAY="$OPTARG" ;;
    m) MAX_ATTEMPTS="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    \?) echo "Error: Invalid option -$OPTARG" >&2; print_usage; exit 2 ;;
    :)  echo "Error: Option -$OPTARG requires an argument." >&2; print_usage; exit 2 ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "Error: -u <url> is required." >&2
  print_usage
  exit 2
fi

# Validate numeric inputs
if ! [[ "$EXPECTED_STATUS" =~ ^[0-9]{3}$ ]]; then
  echo "Error: expected status must be a 3-digit code." >&2
  exit 2
fi
if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  echo "Error: retry delay must be an integer (seconds)." >&2
  exit 2
fi
if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]]; then
  echo "Error: max attempts must be an integer (0 for infinite)." >&2
  exit 2
fi

# Timing and stats
START_SECONDS=$SECONDS
attempt=0
retries=0

# Output control
IS_TTY=0
if [[ -t 2 ]]; then IS_TTY=1; fi    # use stderr for live status

# Helpers for live-updating status line on TTY
clear_line() { 
  # Clear entire line and return carriage
  # shellcheck disable=SC2059
  printf "\r\033[2K" >&2
}
status_line() {
  local msg="$1"
  if [[ "$IS_TTY" -eq 1 ]]; then
    clear_line
    printf "%s" "$msg" >&2
  else
    # Non-TTY: print as a normal line
    printf "%s\n" "$msg" >&2
  fi
}

# Ensure we always print final stats
finish() {
  local elapsed=$(( SECONDS - START_SECONDS ))
  local attempts="$attempt"
  local total_retries="$retries"
  # If we were live-updating on TTY, move to a new line before final output
  if [[ "$IS_TTY" -eq 1 ]]; then printf "\n" >&2; fi

  echo "=== Statistics ==="
  echo "Attempts : $attempts"
  echo "Retries  : $total_retries"
  echo "Runtime  : ${elapsed}s"
}
trap finish EXIT

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

while :; do
  attempt=$((attempt + 1))

  # Perform request:
  # -sS : silent but show errors
  # -k  : allow insecure certs
  # -L  : follow redirects
  # -o  : write body to file
  # -w  : print only HTTP status code to stdout
  HTTP_CODE="$(curl -sS -k -L -o "$BODY_FILE" -w "%{http_code}" "$URL" || true)"

  status_ok=false
  text_ok=true

  if [[ "$HTTP_CODE" == "$EXPECTED_STATUS" ]]; then
    status_ok=true
  fi

  if [[ -n "$REQUIRED_TEXT" ]]; then
    if LC_ALL=C grep -Fq -- "$REQUIRED_TEXT" "$BODY_FILE"; then
      text_ok=true
    else
      text_ok=false
    fi
  fi

  if $status_ok && $text_ok; then
    if [[ "$IS_TTY" -eq 1 ]]; then clear_line; fi
    echo "Success: received expected status $EXPECTED_STATUS" \
         $( [[ -n "$REQUIRED_TEXT" ]] && echo "and found required text" )
    exit 0
  fi

  # Failure path
  retries=$((attempt - 1))

  # Compose failure reason
  if ! $status_ok && ! $text_ok && [[ -n "$REQUIRED_TEXT" ]]; then
    status_line "[attempt $attempt] HTTP $HTTP_CODE (expected $EXPECTED_STATUS) and missing required text — retrying in ${RETRY_DELAY}s..."
  elif ! $status_ok; then
    status_line "[attempt $attempt] HTTP $HTTP_CODE (expected $EXPECTED_STATUS) — retrying in ${RETRY_DELAY}s..."
  elif ! $text_ok; then
    status_line "[attempt $attempt] Required text not found — retrying in ${RETRY_DELAY}s..."
  fi

  # Stop if max attempts reached
  if [[ "$MAX_ATTEMPTS" -ne 0 && "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
    if [[ "$IS_TTY" -eq 1 ]]; then clear_line; fi
    echo "Giving up after $attempt attempts. Last HTTP status: $HTTP_CODE" >&2
    exit 1
  fi

  sleep "$RETRY_DELAY"
done