#!/data/data/com.termux/files/usr/bin/sh
clear
echo -e "\033[1;32m====================================================\033[0m"
echo -e "\033[1;32m       ULTRALYTICS AI - TERMUX MIGRATION RESTORE    \033[0m"
echo -e "\033[1;32m====================================================\033[0m"
echo ""
echo "This script will restore your Termux backup."
echo "It will overwrite files in your current environment."
echo ""
echo -n "Do you want to proceed with the restore? (y/n): "
read -r answer
if [ "$answer" != "${answer#[Yy]}" ]; then
    echo "Starting restore..."
else
    echo "Restore cancelled."
    exit 0
fi

# Scan for backup files in .tmp directories across all storage locations
echo "Scanning for backups..."
backups=()
backup_descriptions=()

# Scan internal and external devices
storage_roots=()
if [ -d "/storage/emulated/0" ]; then
    storage_roots+=("/storage/emulated/0")
fi
for dir in /storage/*; do
    if [ -d "$dir" ] && [ "$dir" != "/storage/self" ] && [ "$dir" != "/storage/emulated" ]; then
        storage_roots+=("$dir")
    fi
done

for root in "${storage_roots[@]}"; do
    if [ -f "$root/.tmp/backup.tar.gz" ]; then
        backups+=("$root/.tmp/backup.tar.gz")
        size_bytes=$(stat -c %s "$root/.tmp/backup.tar.gz" 2>/dev/null || wc -c < "$root/.tmp/backup.tar.gz" 2>/dev/null || echo 0)
        size_mb=$((size_bytes / 1024 / 1024))
        backup_descriptions+=("Backup at $root/.tmp/backup.tar.gz (${size_mb} MB)")
    fi
done

if [ ${#backups[@]} -eq 0 ]; then
    echo -e "\033[1;31mError:\033[0m No backup files found in storage .tmp directories."
    echo -n "Enter custom path to backup.tar.gz if located elsewhere: "
    read -r custom_path
    if [ -f "$custom_path" ]; then
        backups+=("$custom_path")
        backup_descriptions+=("Custom backup at $custom_path")
    else
        echo "File not found. Restore failed."
        exit 1
    fi
fi

# Present selection if multiple backups found
selected_idx=0
if [ ${#backups[@]} -gt 1 ]; then
    echo "Found multiple backups:"
    for i in "${!backup_descriptions[@]}"; do
        echo "  [$i] ${backup_descriptions[$i]}"
    done
    echo -n "Select backup to restore: "
    read -r sel
    selected_idx=$sel
fi

backup_to_restore="${backups[$selected_idx]}"
if [ ! -f "$backup_to_restore" ]; then
    echo "Selected backup file does not exist."
    exit 1
fi

echo "Restoring from $backup_to_restore..."

# Run extraction relative to /
cd / || exit 1
tar -xzf "$backup_to_restore"

echo ""
echo -e "\033[1;32mRestore completed successfully! Please restart Termux.\033[0m"
