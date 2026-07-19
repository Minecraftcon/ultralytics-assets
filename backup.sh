#!/data/data/com.termux/files/usr/bin/sh
clear
echo -e "\033[1;33m====================================================\033[0m"
echo -e "\033[1;33m       ULTRALYTICS AI - TERMUX MIGRATION BACKUP     \033[0m"
echo -e "\033[1;33m====================================================\033[0m"
echo ""
echo -e "\033[1;31mWARNING:\033[0m You are about to backup your Termux environment."
echo "This backup is needed because we must reinstall Termux to match"
echo "the certificate signature of the Ultralytics AI app."
echo ""
echo -n "Do you want to proceed with the backup? (y/n): "
read -r answer
if [ "$answer" != "${answer#[Yy]}" ]; then
    echo "Starting backup process..."
else
    echo "Backup cancelled."
    exit 0
fi

# 1. Scan for storage devices
echo ""
echo "Scanning for storage devices..."
devices=()
device_names=()
default_idx=0

# Internal storage
if [ -d "/storage/emulated/0" ]; then
    devices+=("/storage/emulated/0")
    device_names+=("Internal Storage (/storage/emulated/0)")
fi

# External storage devices
for dir in /storage/*; do
    if [ -d "$dir" ] && [ "$dir" != "/storage/self" ] && [ "$dir" != "/storage/emulated" ]; then
        devices+=("$dir")
        device_names+=("External SD Card / Storage (${dir##*/})")
        default_idx=$(( ${#devices[@]} - 1 ))
    fi
done

if [ ${#devices[@]} -eq 0 ]; then
    echo -e "\033[1;31mError:\033[0m No writeable storage devices found in /storage."
    echo "Please run 'termux-setup-storage' first to grant storage access."
    exit 1
fi

echo "Available storage devices:"
for i in "${!device_names[@]}"; do
    if [ "$i" -eq "$default_idx" ]; then
        echo -e "  [$i] \033[1;32m${device_names[$i]} [Default]\033[0m"
    else
        echo "  [$i] ${device_names[$i]}"
    fi
done

echo -n "Select backup device (press Enter for default): "
read -r sel
if [ -z "$sel" ]; then
    sel=$default_idx
fi

target_device="${devices[$sel]}"
if [ -z "$target_device" ]; then
    echo "Invalid selection."
    exit 1
fi

backup_dir="$target_device/.tmp"
mkdir -p "$backup_dir"
backup_path="$backup_dir/backup.tar.gz"

echo ""
echo "Backup location: $backup_path"

# 2. Check storage space
echo "Calculating space requirements..."
size_home=$(du -sk "$HOME" 2>/dev/null | cut -f1)
size_prefix=$(du -sk "$PREFIX" 2>/dev/null | cut -f1)
total_needed_kb=$((size_home + size_prefix))
total_needed_mb=$((total_needed_kb / 1024))

avail_kb=$(df -P -k "$target_device" | tail -n 1 | awk '{print $4}')
avail_mb=$((avail_kb / 1024))

echo "Space required: ~${total_needed_mb} MB"
echo "Space available: ${avail_mb} MB"

if [ "$total_needed_kb" -gt "$avail_kb" ]; then
    echo -e "\033[1;31m========================================\033[0m"
    echo -e "\033[1;31m             BACKUP FAILED              \033[0m"
    echo -e "\033[1;31m========================================\033[0m"
    echo "Reason: Insufficient storage space on the selected device."
    echo "Available space: ${avail_mb} MB"
    echo "Needed space: ~${total_needed_mb} MB"
    echo "Please free up at least $((total_needed_mb - avail_mb)) MB on the device and try again."
    exit 1
fi

# 3. Perform Backup
echo "Starting backup of HOME ($HOME) and PREFIX ($PREFIX)..."

use_pv=false
if ! command -v pv >/dev/null 2>&1; then
    echo "Attempting to install 'pv' to show real-time progress..."
    pkg install -y pv >/dev/null 2>&1 || apt install -y pv >/dev/null 2>&1
fi

if command -v pv >/dev/null 2>&1; then
    use_pv=true
fi

cd / || exit 1
rel_home="data/data/com.termux/files/home"
rel_prefix="data/data/com.termux/files/usr"

if [ "$use_pv" = true ]; then
    tar -cf - "$rel_home" "$rel_prefix" 2>/dev/null | pv -s "${total_needed_kb}k" | gzip > "$backup_path"
else
    est_compressed_kb=$((total_needed_kb * 4 / 10))
    if [ $est_compressed_kb -le 0 ]; then est_compressed_kb=1; fi
    
    tar -czf "$backup_path" "$rel_home" "$rel_prefix" >/dev/null 2>&1 &
    tar_pid=$!
    
    start_time=$(date +%s)
    last_size=0
    last_time=$start_time
    
    while kill -0 $tar_pid 2>/dev/null; do
        sleep 1
        current_time=$(date +%s)
        if [ -f "$backup_path" ]; then
            current_size_bytes=$(wc -c < "$backup_path" 2>/dev/null || stat -c %s "$backup_path" 2>/dev/null || echo 0)
        else
            current_size_bytes=0
        fi
        current_size_kb=$((current_size_bytes / 1024))
        
        pct=$((current_size_kb * 100 / est_compressed_kb))
        if [ $pct -gt 99 ]; then pct=99; fi
        
        time_diff=$((current_time - last_time))
        if [ $time_diff -le 0 ]; then time_diff=1; fi
        size_diff=$((current_size_kb - last_size))
        speed_kb_s=$((size_diff / time_diff))
        
        num_chars=$((pct / 4))
        bar=$(head -c $num_chars < /dev/zero | tr '\0' '#')
        
        if [ $speed_kb_s -ge 1024 ]; then
            speed_str="$((speed_kb_s / 1024)) MB/s"
        else
            speed_str="${speed_kb_s} KB/s"
        fi
        
        printf "\rProgress: [%-25s] %d%% | Speed: %s" "$bar" "$pct" "$speed_str"
        
        last_size=$current_size_kb
        last_time=$current_time
    done
    wait $tar_pid
    printf "\rProgress: [%-25s] 100%% | Done!               \n" "#########################"
fi

if [ -f "$backup_path" ] && [ -s "$backup_path" ]; then
    echo ""
    echo -e "\033[1;32mBackup successfully saved to: $backup_path\033[0m"
    echo "You can now uninstall this Termux app and install the signed version."
else
    echo ""
    echo -e "\033[1;31mBackup failed to write file.\033[0m"
    exit 1
fi
