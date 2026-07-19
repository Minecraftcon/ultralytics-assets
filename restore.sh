#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  restore.sh — Ultralytics AI · Termux Migration Restore
#  Restores a backup created by backup.sh into the current Termux installation.
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[1;31m'; YLW='\033[1;33m'; GRN='\033[1;32m'; CYN='\033[1;36m'
BLD='\033[1m'; RST='\033[0m'

info()    { printf "${CYN}  →${RST}  %s\n" "$*"; }
success() { printf "${GRN}  ✓${RST}  %s\n" "$*"; }
warn()    { printf "${YLW}  ⚠${RST}  %s\n" "$*"; }
error()   { printf "${RED}  ✗${RST}  %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

banner() {
    printf "\n${GRN}"
    printf '══════════════════════════════════════════════════════\n'
    printf '   ULTRALYTICS AI  ·  Termux Migration Restore Tool  \n'
    printf '══════════════════════════════════════════════════════\n'
    printf "${RST}\n"
}

# ── Banner & confirmation ─────────────────────────────────────────────────────
clear
banner

printf "${BLD}This script restores a Termux backup created by backup.sh.\n"
printf "All existing files in \$HOME and \$PREFIX will be overwritten.${RST}\n\n"

printf "${RED}${BLD}WARNING:${RST} This will overwrite your current Termux environment.\n"
printf "Make sure you are running this inside the freshly installed,\n"
printf "custom-signed Termux before proceeding.\n\n"

read -rp "Proceed with restore? [y/N]: " answer
[[ "${answer,,}" == y* ]] || { info "Restore cancelled."; exit 0; }

# ── 1. Discover backup files ──────────────────────────────────────────────────
echo ""
info "Scanning for backup archives…"

backups=()
labels=()

# Check known .tmp locations across all storage roots
storage_roots=()
[[ -d /storage/emulated/0 ]] && storage_roots+=("/storage/emulated/0")

while IFS= read -r -d '' dir; do
    name="${dir##*/}"
    [[ "$name" == "self" || "$name" == "emulated" ]] && continue
    storage_roots+=("$dir")
done < <(find /storage -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

for root in "${storage_roots[@]}"; do
    candidate="${root}/.tmp/termux_backup.tar.gz"
    # Also accept the old filename from previous script version
    old_candidate="${root}/.tmp/backup.tar.gz"
    for f in "$candidate" "$old_candidate"; do
        if [[ -f "$f" && -s "$f" ]]; then
            size_mb=$(( $(stat -c %s "$f" 2>/dev/null || echo 0) / 1024 / 1024 ))
            backups+=("$f")
            labels+=("${f}  (${size_mb} MB)")
        fi
    done
done

# ── 2. Prompt for manual path if none found ───────────────────────────────────
if [[ ${#backups[@]} -eq 0 ]]; then
    warn "No backup archives found in storage .tmp directories."
    echo ""
    read -rp "  Enter full path to backup.tar.gz: " custom_path
    custom_path="${custom_path//\'/}"   # strip accidental quotes
    if [[ -f "$custom_path" && -s "$custom_path" ]]; then
        size_mb=$(( $(stat -c %s "$custom_path" 2>/dev/null || echo 0) / 1024 / 1024 ))
        backups+=("$custom_path")
        labels+=("${custom_path}  (${size_mb} MB)")
    else
        die "File not found or empty: '${custom_path}'"
    fi
fi

# ── 3. Selection ──────────────────────────────────────────────────────────────
selected_idx=0

if [[ ${#backups[@]} -gt 1 ]]; then
    echo ""
    printf "${BLD}Found %d backup(s):${RST}\n" "${#backups[@]}"
    for i in "${!labels[@]}"; do
        printf "  [%d] %s\n" "$i" "${labels[$i]}"
    done
    echo ""
    read -rp "Select backup to restore [0]: " sel
    sel="${sel:-0}"
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ $sel -ge ${#backups[@]} ]]; then
        die "Invalid selection: '${sel}'"
    fi
    selected_idx=$sel
else
    printf "\n  ${BLD}Found:${RST} %s\n\n" "${labels[0]}"
fi

backup_file="${backups[$selected_idx]}"

# ── 4. Verify archive integrity before extracting ────────────────────────────
info "Verifying archive integrity…"
if ! tar -tzf "$backup_file" &>/dev/null; then
    die "Archive appears corrupt or is not a valid tar.gz: ${backup_file}"
fi
success "Archive integrity OK."

# ── 5. Space check ────────────────────────────────────────────────────────────
info "Checking available space…"

# Estimate uncompressed size (assume ~2.5× compression ratio)
compressed_kb=$(( $(stat -c %s "$backup_file") / 1024 ))
est_uncompressed_kb=$(( compressed_kb * 25 / 10 ))
avail_data_kb=$(df -Pk /data 2>/dev/null | awk 'NR==2{print $4}' || echo 999999999)

if (( est_uncompressed_kb > avail_data_kb )); then
    short=$(( (est_uncompressed_kb - avail_data_kb) / 1024 ))
    die "Estimated ${short} MB short on /data. Free space before continuing."
fi

avail_mb=$(( avail_data_kb / 1024 ))
est_mb=$(( est_uncompressed_kb / 1024 ))
printf "  Estimated restore size : ~%d MB\n" "$est_mb"
printf "  Space available on /data: %d MB\n\n" "$avail_mb"

# ── 6. Restore ────────────────────────────────────────────────────────────────
info "Restoring from ${BLD}${backup_file}${RST}…"
echo ""

use_pv=false
if ! command -v pv &>/dev/null; then
    pkg install -y pv &>/dev/null || true
fi
command -v pv &>/dev/null && use_pv=true

cd /

if [[ "$use_pv" == true ]]; then
    pv -s "${compressed_kb}k" -N "Extracting" "$backup_file" | tar -xzf -
else
    tar -xzf "$backup_file" &
    tar_pid=$!
    BAR_WIDTH=30
    frame=0
    spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while kill -0 "$tar_pid" 2>/dev/null; do
        printf "\r  ${CYN}%s${RST}  Extracting…" "${spin[$(( frame % ${#spin[@]} ))]}"
        (( frame++ ))
        sleep 0.15
    done
    wait "$tar_pid"
    printf "\r  ${GRN}✓${RST}  Extraction complete.%20s\n" ""
fi

# ── 7. Done ───────────────────────────────────────────────────────────────────
echo ""
success "Restore completed successfully!"
echo ""
printf "${YLW}Next steps:${RST}\n"
printf "  1. Run ${BLD}exit${RST} to close this session.\n"
printf "  2. Open Termux again — your environment will be fully restored.\n\n"
