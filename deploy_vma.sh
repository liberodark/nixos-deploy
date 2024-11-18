VMA_PATH="/var/lib/pve/local-btrfs/dump/vzdump-qemu-nixos-24.11beta708443.057f63b6dc1a.vma.zst"
STORAGE="local-btrfs"
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_BRIDGE="vmbr0"
DEFAULT_GATEWAY="192.168.0.1"
DEFAULT_DNS="1.1.1.1"

# Generate random MAC address
generate_mac() {
    printf '52:54:00:%02X:%02X:%02X\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1"
        exit 1
    fi
}

restore_vm() {
    local VM_ID=$1
    local HOSTNAME=$2
    local IP=$3
    local GATEWAY=${4:-$DEFAULT_GATEWAY}
    local MAC=$(generate_mac)

    log "Restoring VM $HOSTNAME (ID: $VM_ID)..."

    if qm status $VM_ID >/dev/null 2>&1; then
        log "VM $VM_ID already exists. Removing..."
        qm stop $VM_ID >/dev/null 2>&1
        qm destroy $VM_ID
    fi

    # Restore VM
    log "Restoring from VMA..."
    qmrestore $VMA_PATH $VM_ID --unique true --storage $STORAGE
    check_error "Failed to restore VM"

    # Configure VM
    log "Configuring VM..."
    qm set $VM_ID \
        --name $HOSTNAME \
        --cores $DEFAULT_CORES \
        --memory $DEFAULT_MEMORY \
        --ipconfig0 "ip=$IP,gw=$GATEWAY" \
        --nameserver $DEFAULT_DNS \
        --net0 "virtio,bridge=$DEFAULT_BRIDGE,macaddr=$MAC"
    check_error "Failed to configure VM"

    # Start VM
    log "Starting VM..."
    qm start $VM_ID
    check_error "Failed to start VM"

    log "VM $HOSTNAME restored and configured successfully."
    log "You can connect via: ssh root@${IP%/*}"
    log "MAC Address: $MAC"
}

case "$1" in
    "restore")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 restore <vm_id> <hostname> <ip> [gateway]"
            exit 1
        fi
        restore_vm "$2" "$3" "$4" "${5:-$DEFAULT_GATEWAY}"
        ;;
    *)
        echo "Usage:"
        echo "  $0 restore <vm_id> <hostname> <ip> [gateway]"
        echo ""
        echo "Example:"
        echo "  $0 restore 100 nixos-test 192.168.0.100/24"
        echo "  $0 restore 100 nixos-test 192.168.0.100/24 192.168.0.1"
        exit 1
        ;;
esac
