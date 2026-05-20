#!/usr/bin/env bash
# sync-env.sh — merge .env.example into .env preserving user values.
#
# Usage:
#   ./sync-env.sh                     # interactive: shows diff, asks to confirm
#   ./sync-env.sh -y                  # skip confirmation (CI / scripted use)
#   ./sync-env.sh -n                  # dry run: show diff, never write
#   ./sync-env.sh [-y|-n] EXAMPLE ENV # custom paths
#
# Rules:
#   - Structure, order and comments come from .env.example.
#   - For every assignment (commented or not) in the example, if the same
#     KEY is already defined (uncommented) in .env, the user's line wins.
#   - Otherwise the line from the example is used verbatim.
#   - Keys present in .env but not in the example are kept at the bottom
#     under a "Legacy / custom" section so nothing is silently lost.
#   - A timestamped backup (.env.bak.YYYYMMDD-HHMMSS) is written before
#     overwriting .env.

set -euo pipefail

assume_yes=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)   assume_yes=1; shift ;;
    -n|--dry-run) dry_run=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) break ;;
  esac
done

EXAMPLE="${1:-.env.example}"
ENV_FILE="${2:-.env}"

[[ -f "$EXAMPLE" ]] || { echo "error: $EXAMPLE not found" >&2; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  if (( dry_run )); then
    echo "[dry-run] would create $ENV_FILE from $EXAMPLE"
    exit 0
  fi
  cp "$EXAMPLE" "$ENV_FILE"
  echo "created $ENV_FILE from $EXAMPLE (no prior file to merge)"
  exit 0
fi

declare -A current
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    current["${BASH_REMATCH[1]}"]="$line"
  fi
done < "$ENV_FILE"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

declare -A seen

while IFS= read -r line || [[ -n "$line" ]]; do
  key=""
  if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    key="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    key="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$key" && -n "${current[$key]+x}" ]]; then
    printf '%s\n' "${current[$key]}" >> "$tmp"
    seen["$key"]=1
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$EXAMPLE"

orphans=()
for k in "${!current[@]}"; do
  [[ -z "${seen[$k]+x}" ]] && orphans+=("$k")
done

if (( ${#orphans[@]} > 0 )); then
  {
    printf '\n'
    printf '# ============================================================================\n'
    printf '# Legacy / custom (present in previous .env but no longer in .env.example)\n'
    printf '# ============================================================================\n'
    for k in "${orphans[@]}"; do
      printf '%s\n' "${current[$k]}"
    done
  } >> "$tmp"
fi

# Count additions (keys in example not present in current .env)
added=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    k="${BASH_REMATCH[1]}"
    [[ -z "${current[$k]+x}" ]] && added=$((added + 1))
  fi
done < "$EXAMPLE"

# No changes?
if cmp -s "$ENV_FILE" "$tmp"; then
  echo "no changes: $ENV_FILE is already in sync with $EXAMPLE"
  exit 0
fi

echo "=== Preview: diff $ENV_FILE -> proposed ==="
if command -v diff >/dev/null 2>&1; then
  diff -u --label "current ($ENV_FILE)" --label "proposed" "$ENV_FILE" "$tmp" || true
else
  echo "(diff not available — printing proposed content in full)"
  cat "$tmp"
fi
echo "==========================================="
echo "summary:"
echo "  preserved: ${#seen[@]} existing key(s)"
echo "  added:     $added new key(s) from $EXAMPLE"
echo "  orphans:   ${#orphans[@]} key(s) kept in 'Legacy / custom' section"
echo

if (( dry_run )); then
  echo "[dry-run] no changes written."
  exit 0
fi

if (( ! assume_yes )); then
  if [[ ! -t 0 ]]; then
    echo "error: not running interactively and no -y given; aborting." >&2
    exit 1
  fi
  read -r -p "Apply these changes to $ENV_FILE? [y/N] " answer
  case "${answer:-}" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 1 ;;
  esac
fi

backup="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$ENV_FILE" "$backup"
cp "$tmp" "$ENV_FILE"

echo "synced: $ENV_FILE  (backup: $backup)"
