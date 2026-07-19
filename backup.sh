#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  backup.sh — Ultralytics AI · Termux Migration Backup
#  Backs up $HOME and $PREFIX to external / internal storage before
#  switching to the custom-signed Termux build.
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

# ── 1. Estimate backup size (OOM-safe) ───────────────────────────────────────
echo ""
info "Estimating backup size…"

# du -sk walks every inode and can spike RAM enough for Android's LMK to kill
# Termux on large installs. We cap it with a hard timeout. If du finishes in
# time, we get an accurate number; if it's killed by timeout (very large env),
# we warn the user and continue with a conservative placeholder.
total_kb=0
if command -v timeout &>/dev/null; then
    total_kb=$(timeout 10 du -sk "$HOME" "$PREFIX" 2>/dev/null \
        | awk '{s+=$1} END{print s+0}') || true
fi

# Validate — empty / non-numeric / zero means du timed out or failed
if ! [[ "$total_kb" =~ ^[0-9]+$ ]] || [[ $total_kb -eq 0 ]]; then
    total_kb=0
fi

if [[ $total_kb -eq 0 ]]; then
    warn "Termux environment is too large to measure quickly."
    warn "Ensure the backup destination has at least 20 GB free."
    total_kb=20971520   # 20 GB conservative placeholder for space checks
    total_mb=20480
    printf "  Estimated backup size : ${YLW}${BLD}~20+ GB${RST}  (could not measure exactly)\n"
else
    total_mb=$(( total_kb / 1024 ))
    printf "  Estimated backup size : ${BLD}~%d MB${RST}\n" "$total_mb"
fi

# ── 2. Discover storage roots ─────────────────────────────────────────────────
echo ""
info "Scanning for available storage devices…"

devices=()
labels=()
avail_kbs=()    # parallel array: free KB per device
has_space=()    # parallel array: 1=enough, 0=too small

_add_device() {
    local path="$1" label="$2"
    local free_kb free_mb
    free_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    free_mb=$(( free_kb / 1024 ))
    devices+=("$path")
    labels+=("$label")
    avail_kbs+=("$free_kb")
    if (( free_kb >= total_kb )); then
        has_space+=(1)
    else
        has_space+=(0)
    fi
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

# ── 3. Device selection with free-space display ───────────────────────────────
DIM='\033[2m'; STR='\033[9m'   # dim, strikethrough (widely supported)

# Pick the first device with enough space as the default
default_idx=0
for i in "${!devices[@]}"; do
    [[ ${has_space[$i]} -eq 1 ]] && { default_idx=$i; break; }
done

echo ""
printf "${BLD}Available storage devices:${RST}  (need ~%d MB)\n" "$total_mb"
echo ""

for i in "${!devices[@]}"; do
    free_kb=${avail_kbs[$i]}
    free_mb=$(( free_kb / 1024 ))
    label="${labels[$i]}"
    path="${devices[$i]}"

    if [[ ${has_space[$i]} -eq 0 ]]; then
        # Not enough space — show dimmed with ✗ and how much is short
        short=$(( total_mb - free_mb ))
        printf "  ${DIM}${RED}[%d]${RST}${DIM} %-35s  %4d MB free  ${RED}✗ need %d MB more${RST}\n" \
            "$i" "$label" "$free_mb" "$short"
    elif [[ $i -eq $default_idx ]]; then
        printf "  ${GRN}[%d]${RST} %-35s  ${GRN}%4d MB free${RST}  ${GRN}✓ default${RST}\n" \
            "$i" "$label" "$free_mb"
    else
        printf "  ${CYN}[%d]${RST} %-35s  ${GRN}%4d MB free${RST}  ✓\n" \
            "$i" "$label" "$free_mb"
    fi
done
echo ""

read -rp "Select device number [${default_idx}]: " sel
sel="${sel:-$default_idx}"

if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ $sel -ge ${#devices[@]} ]]; then
    die "Invalid selection: '${sel}'"
fi

if [[ ${has_space[$sel]} -eq 0 ]]; then
    free_mb=$(( avail_kbs[$sel] / 1024 ))
    short=$(( total_mb - free_mb ))
    die "Device [${sel}] does not have enough free space (need ~${total_mb} MB, have ${free_mb} MB).\nFree at least ${short} MB and try again."
fi

target="${devices[$sel]}"
backup_dir="${target}/.tmp"
BACKUP_PATH="${backup_dir}/termux_backup.tar.gz"

mkdir -p "$backup_dir" || die "Cannot create backup directory: $backup_dir"
avail_kb=${avail_kbs[$sel]}
avail_mb=$(( avail_kb / 1024 ))
echo ""
info "Backup will be saved to: ${BLD}${BACKUP_PATH}${RST}"
printf "  Space needed   : ~%d MB\n" "$total_mb"
printf "  Space available:  %d MB\n\n" "$avail_mb"

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
        | pv -s "${total_kb}k" -N "Archiving" \
        | gzip -6 > "$BACKUP_PATH"
else
    # Estimate compressed size (~40 % of raw)
    est_kb=$(( total_kb * 4 / 10 ))
    (( est_kb < 1 )) && est_kb=1

    tar -czf "$BACKUP_PATH" "$REL_HOME" "$REL_PFX" &>/dev/null &
    tar_pid=$!

    last_kb=0
    last_ts=$(date +%s)
    BAR_WIDTH=30

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
        "$(printf '█%.0s' $(seq 1 $BAR_WIDTH))" ""
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
