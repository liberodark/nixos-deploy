#!/bin/bash

# Default configuration
TEMPLATE="/var/lib/pve/local-btrfs/template/cache/nixos-24.05-default_20241108_amd64.tar.xz"
STORAGE="local-btrfs"
BRIDGE="vmbr0"
DEFAULT_GATEWAY="192.168.0.1"
DEFAULT_DNS="1.1.1.1"
DEFAULT_PRIVILEGED=1
DEFAULT_CORES=2
DEFAULT_MEMORY=1024
DEFAULT_DISK=8

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error-checking function
check_error() {
    if [ $? -ne 0 ]; then
        log "ERROR: $1"
        exit 1
    fi
}

# Function to wait for container to be running
wait_for_container() {
    local CT_ID=$1
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if pct status $CT_ID 2>/dev/null | grep -q "status: running"; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Function to generate NixOS configuration
generate_nixos_config() {
    local HOSTNAME=$1
    local IP=${2%/*}  # Removes /24 from the IP
    local PREFIX=${2#*/}  # Gets the prefix after /
    local GATEWAY=${3:-$DEFAULT_GATEWAY}

    cat << EOF
{ modulesPath, config, pkgs, ... }:

{
  imports = [
    "\${modulesPath}/virtualisation/lxc-container.nix"
  ];

  boot.isContainer = true;

  # Disable swap
  swapDevices = [];

  # Remove systemd units incompatible with LXC
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # Network configuration with static IP
  networking = {
    hostName = "$HOSTNAME";
    dhcpcd.enable = false;
    enableIPv6 = false;
    useHostResolvConf = false;
    nameservers = [ "'$DEFAULT_DNS'" ];
    defaultGateway = "$GATEWAY";
    
    # eth0 interface configuration
    interfaces.eth0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "$IP";
          prefixLength = $PREFIX;
        }
      ];
    };
  };

  # Basic services
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  # Basic packages
  environment.systemPackages = with pkgs; [
    nano
    wget
    htop
    binutils
    man
  ];

  system.stateVersion = "24.05";
}
EOF
}

# Function to create a container
create_container() {
    local CT_ID=$1
    local HOSTNAME=$2
    local IP=$3
    local GATEWAY=${4:-$DEFAULT_GATEWAY}
    local CORES=${5:-$DEFAULT_CORES}
    local MEMORY=${6:-$DEFAULT_MEMORY}
    local DISK=${7:-$DEFAULT_DISK}
    local PRIVILEGED=${8:-$DEFAULT_PRIVILEGED}

    log "Creating container $HOSTNAME (ID: $CT_ID)..."
    log "Configuration: Cores=$CORES, Memory=$MEMORY MB, Disk=$DISK GB, Privileged=$PRIVILEGED"

    # Check if the container already exists
    if pct status $CT_ID >/dev/null 2>&1; then
        log "Container $CT_ID already exists. Removing..."
        pct stop $CT_ID >/dev/null 2>&1
        pct destroy $CT_ID
    fi

    # Create the container
    pct create $CT_ID $TEMPLATE \
        --arch amd64 \
        --ostype unmanaged \
        --hostname $HOSTNAME \
        --cores $CORES \
        --memory $MEMORY \
        --swap 0 \
        --rootfs $STORAGE:$DISK \
        --net0 "name=eth0,bridge=$BRIDGE" \
        --unprivileged $([[ $PRIVILEGED == 1 ]] && echo "0" || echo "1") \
        --features nesting=1 \
        --force 1
    check_error "Failed to create container"

    # Start the container
    log "Starting the container..."
    pct start $CT_ID
    check_error "Failed to start the container"

    # Wait for the container to be running
    log "Waiting for container to be running..."
    if ! wait_for_container $CT_ID; then
        log "ERROR: Container failed to start properly"
        exit 1
    fi

    # Create NixOS configuration in the container
    log "Creating NixOS configuration..."
    generate_nixos_config "$HOSTNAME" "$IP" "$GATEWAY" | pct exec $CT_ID -- /run/current-system/sw/bin/tee /etc/nixos/configuration.nix > /dev/null 2>&1
    check_error "Failed to create configuration file"

    # Apply Network Configuration
    log "Applying Network configuration..."
    pct exec $CT_ID -- /run/current-system/sw/bin/su -c "ip link set eth0 up" root
    pct exec $CT_ID -- /run/current-system/sw/bin/su -c "ip addr add $IP dev eth0" root
    pct exec $CT_ID -- /run/current-system/sw/bin/su -c "ip route add default via $GATEWAY" root
    pct exec $CT_ID -- /run/current-system/sw/bin/su -c "echo 'nameserver $DEFAULT_DNS' > /etc/resolv.conf" root
    check_error "Network configuration Failed"

    # Run nixos-rebuild
    log "Applying NixOS configuration..."
    pct exec $CT_ID -- /run/current-system/sw/bin/su -c "nixos-rebuild switch" root > /dev/null 2>&1
    check_error "Configuration Failed"
    log "Container $HOSTNAME created and configured successfully."
}

# Function to deploy multiple containers
deploy_cluster() {
    local BASE_ID=$1
    local COUNT=$2
    local BASE_IP=$3
    local GATEWAY=${4:-$DEFAULT_GATEWAY}
    local PRIVILEGED=${5:-$DEFAULT_PRIVILEGED}

    log "Deploying a cluster of $COUNT containers..."
    
    # Check parameters
    if ! [[ $COUNT =~ ^[0-9]+$ ]]; then
        log "ERROR: The number of containers must be an integer"
        exit 1
    fi

    if [[ $COUNT -lt 1 ]]; then
        log "ERROR: The number of containers must be greater than 0"
        exit 1
    fi

    # Extract components of the base IP
    local BASE_ADDR=${BASE_IP%.*}
    local LAST_OCTET=${BASE_IP##*.}
    local PREFIX="24"
    if [[ $LAST_OCTET =~ ^([0-9]+)(/[0-9]+)?$ ]]; then
        LAST_OCTET=${BASH_REMATCH[1]}
        PREFIX=${BASH_REMATCH[2]#/}
    fi

    # Create containers
    for i in $(seq 0 $((COUNT-1))); do
        local CT_ID=$((BASE_ID + i))
        local NEW_OCTET=$((LAST_OCTET + i))
        
        if [[ $NEW_OCTET -gt 254 ]]; then
            log "ERROR: IP range exceeded for container $i"
            exit 1
        fi
        
        local HOSTNAME="nixos-node-$i"
        local IP="$BASE_ADDR.$NEW_OCTET/$PREFIX"
        
        create_container $CT_ID $HOSTNAME $IP $GATEWAY $DEFAULT_CORES $DEFAULT_MEMORY $DEFAULT_DISK $PRIVILEGED
    done

    log "Cluster deployment completed successfully."
}

# Function to check container status
check_containers() {
    local BASE_ID=$1
    local COUNT=$2

    log "Checking containers..."
    for i in $(seq 0 $((COUNT-1))); do
        local CT_ID=$((BASE_ID + i))
        log "Status of container $CT_ID:"
        pct status $CT_ID
        if [ $? -eq 0 ]; then
            pct exec $CT_ID -- /run/current-system/sw/bin/bash -c 'ip addr show eth0; ping -c 1 192.168.0.1 || true'
        fi
    done
}

# Function to stop and remove containers
cleanup_containers() {
    local BASE_ID=$1
    local COUNT=$2

    log "Cleaning up containers..."
    for i in $(seq 0 $((COUNT-1))); do
        local CT_ID=$((BASE_ID + i))
        log "Removing container $CT_ID..."
        pct stop $CT_ID >/dev/null 2>&1
        pct destroy $CT_ID
    done
    log "Cleanup completed."
}

# Main menu
case "$1" in
    "create")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 create <ct_id> <hostname> <ip> [gateway] [cores] [memory] [disk] [privileged]"
            echo "Note: Default values are: cores=$DEFAULT_CORES, memory=$DEFAULT_MEMORY MB, disk=$DEFAULT_DISK GB, privileged=yes"
            exit 1
        fi
        create_container "$2" "$3" "$4" "${5:-$DEFAULT_GATEWAY}" "${6:-$DEFAULT_CORES}" "${7:-$DEFAULT_MEMORY}" "${8:-$DEFAULT_DISK}" "${9:-$DEFAULT_PRIVILEGED}"
        ;;
    "deploy-cluster")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 deploy-cluster <base_id> <count> <base_ip> [gateway] [privileged]"
            echo "Note: Containers are created with: cores=$DEFAULT_CORES, memory=$DEFAULT_MEMORY MB, disk=$DEFAULT_DISK GB"
            exit 1
        fi
        deploy_cluster "$2" "$3" "$4" "${5:-$DEFAULT_GATEWAY}" "${6:-$DEFAULT_PRIVILEGED}"
        ;;
    "check")
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 check <base_id> <count>"
            exit 1
        fi
        check_containers "$2" "$3"
        ;;
    "cleanup")
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 cleanup <base_id> <count>"
            exit 1
        fi
        cleanup_containers "$2" "$3"
        ;;
    *)
        echo "Usage:"
        echo "  $0 create <ct_id> <hostname> <ip> [gateway] [cores] [memory] [disk] [privileged]"
        echo "  $0 deploy-cluster <base_id> <count> <base_ip> [gateway] [privileged]"
        echo "  $0 check <base_id> <count>"
        echo "  $0 cleanup <base_id> <count>"
        echo ""
        echo "Default values:"
        echo "  - Cores: $DEFAULT_CORES"
        echo "  - Memory: $DEFAULT_MEMORY MB"
        echo "  - Disk: $DEFAULT_DISK GB"
        echo "  - Gateway: $DEFAULT_GATEWAY"
        echo "  - Privileged: yes (use privileged=0 for unprivileged)"
        echo ""
        echo "Examples:"
        echo "  $0 create 100 nixos-test 192.168.0.100/24"
        echo "  $0 create 100 nixos-test 192.168.0.100/24 192.168.0.1"
        echo "  $0 create 100 nixos-test 192.168.0.100/24 192.168.0.1 4 4096 16"
        echo "  $0 create 100 nixos-test 192.168.0.100/24 192.168.0.1 4 4096 16 0  # Unprivileged"
        echo "  $0 deploy-cluster 100 3 192.168.0.100/24"
        echo "  $0 deploy-cluster 100 3 192.168.0.100/24 192.168.0.1"
        echo "  $0 deploy-cluster 100 3 192.168.0.100/24 192.168.0.1 0  # Unprivileged"
        echo "  $0 check 100 3"
        echo "  $0 cleanup 100 3"
        exit 1
        ;;
esac
