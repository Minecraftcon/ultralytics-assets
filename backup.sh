#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  backup.sh — Ultralytics AI · Termux Migration Backup
#  Backs up $HOME and $PREFIX to external / internal storage before
#  switching to the custom-signed Termux build.
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED=$'\033[1;31m'; YLW=$'\033[1;33m'; GRN=$'\033[1;32m'; CYN=$'\033[1;36m'
BLD=$'\033[1m';  RST=$'\033[0m';  DIM=$'\033[2m'

info()    { printf "${CYN}  →${RST}  %s\n" "$*"; }
success() { printf "${GRN}  ✓${RST}  %s\n" "$*"; }
warn()    { printf "${YLW}  ⚠${RST}  %s\n" "$*"; }
error()   { printf "${RED}  ✗${RST}  %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

banner() {
    printf "\n${YLW}"
    printf '══════════════════════════════════════════════════════\n'
    printf '   ULTRALYTICS AI  ·  Termux Migration Backup Tool   \n'
    printf '══════════════════════════════════════════════════════\n'
    printf "${RST}\n"
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
BACKUP_PATH=""
cleanup() {
    local code=$?
    if [[ $code -ne 0 && -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]]; then
        warn "Removing incomplete backup file…"
        rm -f "$BACKUP_PATH"
    fi
}
trap cleanup EXIT

# ── Banner & confirmation ─────────────────────────────────────────────────────
clear
banner

printf "${BLD}This script backs up your Termux environment (\$HOME + \$PREFIX).\n"
printf "Required so you can reinstall the custom-signed Termux build\n"
printf "that is compatible with Ultralytics AI's Unix socket bridge.${RST}\n\n"

printf "${RED}${BLD}WARNING:${RST} All files inside Termux will be archived.\n"
printf "The backup may take several minutes on large environments.\n\n"

read -rp "Proceed with backup? [y/N]: " answer
[[ "${answer,,}" == y* ]] || { info "Backup cancelled."; exit 0; }

# ── 1. Discover storage devices ──────────────────────────────────────────────
echo ""
info "Scanning for available storage devices…"

devices=()
labels=()
avail_kbs=()   # free KB per device

_add_device() {
    local path="$1" label="$2" free_kb
    free_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')
    # Guard: must be a non-empty integer
    [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
    devices+=("$path")
    labels+=("$label")
    avail_kbs+=("$free_kb")
}

if [[ -d /storage/emulated/0 ]]; then
    _add_device "/storage/emulated/0" "Internal Storage"
fi

while IFS= read -r -d '' dir; do
    name="${dir##*/}"
    [[ "$name" == "self" || "$name" == "emulated" ]] && continue
    _add_device "$dir" "External Storage (${name})"
done < <(find /storage -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

if [[ ${#devices[@]} -eq 0 ]]; then
    die "No writable storage found. Run 'termux-setup-storage' first."
fi

# ── 2. Device selection ───────────────────────────────────────────────────────
# Thresholds (KB):
MIN_KB=524288      # 512 MB  — hard block, unusable
WARN_KB=2097152    # 2 GB    — yellow caution
# (DIM already defined above)

# Default = device with most free space
default_idx=0
best_kb=0
for i in "${!devices[@]}"; do
    if (( avail_kbs[i] > best_kb )); then
        best_kb=${avail_kbs[i]}
        default_idx=$i
    fi
done

echo ""
printf "${BLD}Available storage devices:${RST}\n"
echo ""

for i in "${!devices[@]}"; do
    free_kb=${avail_kbs[$i]}
    free_mb=$(( free_kb / 1024 ))
    label="${labels[$i]}"

    if (( free_kb < MIN_KB )); then
        # Hard block — not enough for any meaningful backup
        printf "  ${DIM}${RED}[%d]${RST}${DIM} %-35s  %6d MB free  ${RED}✗ too little space${RST}\n" \
            "$i" "$label" "$free_mb"
    elif (( free_kb < WARN_KB )); then
        # Caution — might be enough, might not
        printf "  ${YLW}[%d]${RST} %-35s  ${YLW}%6d MB free  ⚠ low${RST}\n" \
            "$i" "$label" "$free_mb"
    elif [[ $i -eq $default_idx ]]; then
        printf "  ${GRN}[%d]${RST} %-35s  ${GRN}%6d MB free  ✓ default${RST}\n" \
            "$i" "$label" "$free_mb"
    else
        printf "  ${CYN}[%d]${RST} %-35s  ${GRN}%6d MB free  ✓${RST}\n" \
            "$i" "$label" "$free_mb"
    fi
done
echo ""

read -rp "Select device number [${default_idx}]: " sel
sel="${sel:-$default_idx}"

if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel >= ${#devices[@]} )); then
    die "Invalid selection: '${sel}'"
fi

if (( avail_kbs[sel] < MIN_KB )); then
    free_mb=$(( avail_kbs[sel] / 1024 ))
    die "Device [${sel}] has only ${free_mb} MB free — not enough for a backup.\nFree space or choose another device."
fi

if (( avail_kbs[sel] < WARN_KB )); then
    free_mb=$(( avail_kbs[sel] / 1024 ))
    warn "Only ${free_mb} MB free on selected device — backup may fail if Termux data is larger."
    read -rp "Continue anyway? [y/N]: " cont
    [[ "${cont,,}" == y* ]] || { info "Backup cancelled."; exit 0; }
fi

target="${devices[$sel]}"
backup_dir="${target}/.tmp"
BACKUP_PATH="${backup_dir}/termux_backup.tar.gz"

mkdir -p "$backup_dir" || die "Cannot create backup directory: $backup_dir"
avail_kb=${avail_kbs[$sel]:-0}
avail_mb=$(( avail_kb / 1024 ))
echo ""
info "Backup will be saved to: ${BLD}${BACKUP_PATH}${RST}"
printf "  Space available on device: %d MB\n\n" "$avail_mb"

# ── 4. Install pv for progress (optional) ────────────────────────────────────
use_pv=false
if ! command -v pv &>/dev/null; then
    info "Installing 'pv' for real-time progress display…"
    pkg install -y pv &>/dev/null || true
fi
command -v pv &>/dev/null && use_pv=true

# ── 5. Perform backup ─────────────────────────────────────────────────────────
info "Starting backup of Termux environment…"
echo ""

REL_HOME="data/data/com.termux/files/home"
REL_PFX="data/data/com.termux/files/usr"

cd /

if [[ "$use_pv" == true ]]; then
    tar -cf - "$REL_HOME" "$REL_PFX" 2>/dev/null \
        | pv -N "Archiving" \
        | gzip -6 > "$BACKUP_PATH"
else
    # Track progress by watching the growing output file size
    est_kb=$(( avail_kb / 2 ))
    (( est_kb < 1 )) && est_kb=1

    last_kb=0
    last_ts=$(date +%s)
    BAR_WIDTH=30

    tar -czf "$BACKUP_PATH" "$REL_HOME" "$REL_PFX" &>/dev/null &
    tar_pid=$!

    while kill -0 "$tar_pid" 2>/dev/null; do
        sleep 1
        now=$(date +%s)

        cur_bytes=0
        [[ -f "$BACKUP_PATH" ]] && cur_bytes=$(stat -c %s "$BACKUP_PATH" 2>/dev/null || echo 0)
        cur_kb=$(( cur_bytes / 1024 ))

        pct=$(( cur_kb * 100 / est_kb ))
        (( pct > 99 )) && pct=99

        dt=$(( now - last_ts ))
        (( dt < 1 )) && dt=1
        speed_kb=$(( (cur_kb - last_kb) / dt ))

        filled=$(( pct * BAR_WIDTH / 100 ))
        bar=""
        for (( b=0; b<BAR_WIDTH; b++ )); do
            if (( b < filled )); then bar+="█"
            else bar+="░"
            fi
        done

        if (( speed_kb >= 1024 )); then
            spd_str="$(( speed_kb / 1024 )) MB/s"
        else
            spd_str="${speed_kb} KB/s"
        fi

        printf "\r  ${CYN}[%s]${RST} %3d%% │ %s" "$bar" "$pct" "$spd_str"

        last_kb=$cur_kb
        last_ts=$now
    done

    wait "$tar_pid"
    printf "\r  ${GRN}[%s]${RST} 100%% │ Done!%30s\n" \
        "$(printf '█%.0s' $(seq 1 "$BAR_WIDTH"))" ""
fi

# ── 6. Verify & report ────────────────────────────────────────────────────────
echo ""
if [[ ! -s "$BACKUP_PATH" ]]; then
    die "Backup file is empty or missing — something went wrong."
fi

final_mb=$(( $(stat -c %s "$BACKUP_PATH") / 1024 / 1024 ))
success "Backup complete!"
printf "\n  ${BLD}File   :${RST} %s\n" "$BACKUP_PATH"
printf   "  ${BLD}Size   :${RST} %d MB\n\n" "$final_mb"

printf "${YLW}Next steps:${RST}\n"
printf "  1. Uninstall Termux (and Termux:X11) from your device.\n"
printf "  2. Install the signed builds provided by Ultralytics AI.\n"
printf "  3. Run ${BLD}restore.sh${RST} inside the new Termux to restore your data.\n\n"
