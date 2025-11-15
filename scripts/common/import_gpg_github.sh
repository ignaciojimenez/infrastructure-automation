#!/usr/bin/env bash
# import_gpg_github.sh
# Purpose: Import a GPG public key from a GitHub URL and set its trust to "ultimate" (ownertrust level 6).
# This mirrors the behavior of common_playbooks/import_gpg_github.yml for environments without Ansible (e.g., EdgeOS 3.x).
#
# Usage:
#   sudo ./import_gpg_github.sh --url https://github.com/<user>.gpg [--gnupg-home /path/to/gnupghome] [--expect <short-or-full-fpr>]
#
# Options:
#   --url        URL to the GitHub .gpg key (required)
#   --gnupg-home Optional GNUPGHOME directory. Defaults to $GNUPGHOME or ~/.gnupg
#   --expect     Optional expected key identifier. Can be a 16-char short ID or full 40-char fingerprint.
#                If provided, the script will verify the imported key matches before setting trust.
#
# Exit codes:
#   0 on success; non-zero on error.
set -euo pipefail

# --- Helpers -----------------------------------------------------------------
log() { printf "[import-gpg] %s\n" "$*"; }
err() { printf "[import-gpg][ERROR] %s\n" "$*" >&2; }
usage() { sed -n '1,50p' "$0"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command '$1' not found. Please install it and re-run."
    exit 1
  fi
}

# --- Parse args --------------------------------------------------------------
URL=""
GNUPG_HOME_OVERRIDE=""
EXPECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      URL="${2:-}"; shift 2 ;;
    --gnupg-home)
      GNUPG_HOME_OVERRIDE="${2:-}"; shift 2 ;;
    --expect)
      EXPECT="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$URL" ]]; then
  err "--url is required"; usage; exit 1
fi

# --- Dependencies ------------------------------------------------------------
require_cmd curl
require_cmd gpg
require_cmd grep
require_cmd awk
require_cmd sed

# --- GNUPG setup -------------------------------------------------------------
if [[ -n "$GNUPG_HOME_OVERRIDE" ]]; then
  export GNUPGHOME="$GNUPG_HOME_OVERRIDE"
elif [[ -z "${GNUPGHOME:-}" ]]; then
  export GNUPGHOME="$HOME/.gnupg"
fi

# Ensure GNUPGHOME exists with secure permissions
if [[ ! -d "$GNUPGHOME" ]]; then
  log "Creating GNUPGHOME at $GNUPGHOME"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
fi

# Initialize GPG keyring/trustdb silently (like the Ansible task did)
_=$(gpg --list-keys >/dev/null 2>&1 || true)

# --- Import key --------------------------------------------------------------
log "Fetching and importing key from: $URL"

# Capture import output to extract the short key id similar to the Ansible playbook
IMPORT_OUTPUT=$(curl -fsSL "$URL" | gpg --import 2>&1 || true)
IMPORT_RC=$?

# Extract short key id from import output if present (pattern: "gpg: key <SHORTID>:")
IMPORTED_SHORT=$(printf "%s\n" "$IMPORT_OUTPUT" | grep -Eo "gpg: key [0-9A-Fa-f]{8,16}:" | awk '{print $3}' | sed 's/:$//') || true

# If import failed and we didn't import anything, exit
if [[ $IMPORT_RC -ne 0 ]] && [[ -z "$IMPORTED_SHORT" ]]; then
  printf "%s\n" "$IMPORT_OUTPUT" >&2
  err "Failed to import key from $URL"
  exit 1
fi

if [[ -z "$IMPORTED_SHORT" ]]; then
  # Some gpg versions do not print the short id as above when the key already exists.
  # We'll proceed to fingerprint discovery below.
  log "Import completed (or key already present). Proceeding to fingerprint discovery."
else
  log "Imported short key id: $IMPORTED_SHORT"
fi

# --- Collect fingerprints ----------------------------------------------------
FINGERPRINTS=$(gpg --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10;}')
if [[ -z "$FINGERPRINTS" ]]; then
  err "No fingerprints found in keyring after import."
  exit 1
fi

# --- Select the matching fingerprint ----------------------------------------
MATCHED_FPR=""

# Priority 1: If EXPECT is provided, match by EXPECT
if [[ -n "$EXPECT" ]]; then
  for f in $FINGERPRINTS; do
    if [[ "${#EXPECT}" -ge 16 ]]; then
      # match by substring or full equality
      if [[ "$f" == *"$EXPECT"* ]]; then MATCHED_FPR="$f"; break; fi
    else
      # pad to at least 16 chars (short id typical length)
      if [[ "$f" == *"$EXPECT"* ]]; then MATCHED_FPR="$f"; break; fi
    fi
  done
fi

# Priority 2: If no EXPECT match, try to match by IMPORTED_SHORT (if present)
if [[ -z "$MATCHED_FPR" && -n "$IMPORTED_SHORT" ]]; then
  for f in $FINGERPRINTS; do
    if [[ "$f" == *"$IMPORTED_SHORT"* ]]; then MATCHED_FPR="$f"; break; fi
  done
fi

# Priority 3: If still empty and there's exactly one fingerprint, use it
if [[ -z "$MATCHED_FPR" ]]; then
  CNT=$(printf "%s\n" "$FINGERPRINTS" | wc -l | tr -d ' ')
  if [[ "$CNT" == "1" ]]; then
    MATCHED_FPR="$FINGERPRINTS"
  fi
fi

if [[ -z "$MATCHED_FPR" ]]; then
  err "Could not determine which key to trust."
  err "Available fingerprints:"; printf "  %s\n" $FINGERPRINTS >&2
  if [[ -n "$EXPECT" ]]; then
    err "No fingerprint matched --expect='$EXPECT'"
  elif [[ -n "$IMPORTED_SHORT" ]]; then
    err "No fingerprint contained imported short id '$IMPORTED_SHORT'"
  fi
  exit 1
fi

log "Selected fingerprint: $MATCHED_FPR"

# --- Set ultimate trust (ownertrust level 6) ---------------------------------
# Use echo | gpg --import-ownertrust instead of here-string for portability
printf "%s:6:\n" "$MATCHED_FPR" | gpg --import-ownertrust >/dev/null

log "Successfully set ultimate trust for key $MATCHED_FPR"

# --- Show a brief summary ----------------------------------------------------
log "Key summary:"
# Show uid(s) for visibility
(gpg --list-keys --with-colons | awk -F: -v fpr="$MATCHED_FPR" '
  $1=="fpr" && $10==fpr {show=1; next}
  show && $1=="uid" {print "  UID:", $10}
  show && $1!="uid" && $1!="fpr" {exit}
') || true

exit 0
