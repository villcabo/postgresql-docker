#!/usr/bin/env bash
# pgtune-apply.sh — turn a pgtune output file into POSTGRES_COMMAND in .env.
#
# Usage (from the repo root):
#   ./scripts/pgtune-apply.sh                    # default: pgtune.txt -> .env
#   ./scripts/pgtune-apply.sh path/to/pgtune.txt # custom input
#   ./scripts/pgtune-apply.sh INPUT ENV          # custom input + .env path
#   ./scripts/pgtune-apply.sh -n                 # dry-run (preview only)
#   ./scripts/pgtune-apply.sh -y                 # skip confirmation (CI use)
#
# Workflow:
#   1. Generate values at https://pgtune.leopard.in.ua/ for your hardware.
#   2. Copy the right-hand block into a file (default name: pgtune.txt).
#   3. Run this script. It will:
#        - Parse every `key = value` line (ignoring comments / blanks).
#        - Build POSTGRES_COMMAND="-c key=value -c key=value ...".
#        - Compute SHM_SIZE = shared_buffers + 500 MB (Docker needs this).
#        - Show a unified diff + summary, ask for confirmation.
#        - Apply on confirm, with a timestamped backup of .env.
#
# Notes:
#   - Lines pgtune marks as build-conditional (wal_compression=lz4,
#     io_method=io_uring) are copied verbatim. If your postgres image
#     wasn't built with those features, edit pgtune.txt to remove them
#     before running, or PG will fail to start with a clear error.

set -euo pipefail

assume_yes=0
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     assume_yes=1; shift ;;
    -n|--dry-run) dry_run=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) break ;;
  esac
done

# Resolve repo root so the script works from any cwd.
if root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null); then
  cd "$root"
fi

INPUT="${1:-pgtune.txt}"
ENV_FILE="${2:-.env}"

[[ -f "$INPUT"    ]] || { echo "error: input file '$INPUT' not found"   >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "error: '$ENV_FILE' not found"           >&2; exit 1; }

# ---- Parse pgtune file ----
flags=""
shared_buffers=""
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # trim trailing whitespace
    value="${value%"${value##*[![:space:]]}"}"
    [[ -n "$flags" ]] && flags+=" "
    flags+="-c ${key}=${value}"
    count=$((count + 1))
    [[ "$key" == "shared_buffers" ]] && shared_buffers="$value"
  fi
done < "$INPUT"

(( count > 0 )) || { echo "error: no settings parsed from '$INPUT'" >&2; exit 1; }

# ---- Compute SHM_SIZE ----
shm_size=""
shm_reason=""
if [[ -n "$shared_buffers" ]]; then
  if [[ "$shared_buffers" =~ ^([0-9]+)[[:space:]]*([kKmMgG][bB]?)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-MB}"
    unit_upper=$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')
    case "$unit_upper" in
      KB|K)    sb_mb=$(( num / 1024 )) ;;
      MB|M)    sb_mb=$num ;;
      GB|G)    sb_mb=$(( num * 1024 )) ;;
      *)       sb_mb=$num ;;
    esac
    target=$(( sb_mb + 500 ))
    shm_size="${target}mb"
    shm_reason="shared_buffers=$shared_buffers + 500 MB headroom"
  fi
fi

new_command="POSTGRES_COMMAND=\"$flags\""
new_shm="SHM_SIZE=$shm_size"

# ---- Build proposed .env ----
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

found_cmd=0
found_shm=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^POSTGRES_COMMAND= ]]; then
    printf '%s\n' "$new_command" >> "$tmp"
    found_cmd=1
  elif [[ "$line" =~ ^SHM_SIZE= ]]; then
    if [[ -n "$shm_size" ]]; then
      printf '%s\n' "$new_shm" >> "$tmp"
      found_shm=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$ENV_FILE"

if (( ! found_cmd )); then
  printf '\n# Applied by pgtune-apply.sh from %s\n%s\n' "$INPUT" "$new_command" >> "$tmp"
fi
if [[ -n "$shm_size" ]] && (( ! found_shm )); then
  printf '%s\n' "$new_shm" >> "$tmp"
fi

# ---- No-op? ----
if cmp -s "$ENV_FILE" "$tmp"; then
  echo "no changes: $ENV_FILE already matches '$INPUT'"
  exit 0
fi

# ---- Preview ----
echo "=== Preview: diff $ENV_FILE -> proposed ==="
if command -v diff >/dev/null 2>&1; then
  diff -u --label "current ($ENV_FILE)" --label "proposed" "$ENV_FILE" "$tmp" || true
else
  echo "(diff not available — showing proposed file in full)"
  cat "$tmp"
fi
echo "==========================================="
echo "summary:"
echo "  source:           $INPUT ($count settings)"
echo "  POSTGRES_COMMAND: $( (( found_cmd )) && echo replaced || echo appended )"
if [[ -n "$shm_size" ]]; then
  echo "  SHM_SIZE:         $shm_size ($( (( found_shm )) && echo replaced || echo appended ); $shm_reason)"
else
  echo "  SHM_SIZE:         unchanged (no shared_buffers found in input)"
fi
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

echo "applied: $ENV_FILE  (backup: $backup)"
