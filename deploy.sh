#!/bin/bash

# Default configuration
TEMPLATE="/var/lib/pve/local-btrfs/template/cache/nixos-24.05-default_20241108_amd64.tar.xz"
STORAGE="local-btrfs"
BRIDGE="vmbr0"

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

# Function to generate NixOS configuration
generate_nixos_config() {
    local HOSTNAME=$1
    local IP=${2%/*}  # Removes /24 from the IP
    local PREFIX=${2#*/}  # Gets the prefix after /

    cat << EOF
{ modulesPath, config, pkgs, ... }:

{
  imports = [
    "\${modulesPath}/virtualisation/lxc-container.nix"
  ];

  boot.isContainer = true;

  # Remove systemd units incompatible with LXC
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # Network configuration with static IP
  networking = {
    hostName = "$HOSTNAME";
    useHostResolvConf = false;
    nameservers = [ "8.8.8.8" "1.1.1.1" ];
    defaultGateway = "192.168.0.1";
    
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
    local CORES=${4:-2}
    local MEMORY=${5:-2048}
    local DISK=${6:-8}

    log "Creating container $HOSTNAME (ID: $CT_ID)..."

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
        --rootfs $STORAGE:$DISK \
        --net0 "name=eth0,bridge=$BRIDGE" \
        --unprivileged 1 \
        --features nesting=1 \
        --force 1
    check_error "Failed to create container"

    # Start the container
    log "Starting the container..."
    pct start $CT_ID
    check_error "Failed to start the container"

    # Wait for the system to be ready
    log "Waiting for startup..."
    sleep 15

    # Create NixOS configuration in the container
    log "Creating NixOS configuration..."
    generate_nixos_config "$HOSTNAME" "$IP" | pct exec $CT_ID -- /run/current-system/sw/bin/tee /etc/nixos/configuration.nix > /dev/null 2>&1
    check_error "Failed to create configuration file"

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
        
        create_container $CT_ID $HOSTNAME $IP
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
            echo "Usage: $0 create <ct_id> <hostname> <ip>"
            exit 1
        fi
        create_container $2 $3 $4
        ;;
    "deploy-cluster")
        if [ "$#" -lt 4 ]; then
            echo "Usage: $0 deploy-cluster <base_id> <count> <base_ip>"
            exit 1
        fi
        deploy_cluster $2 $3 $4
        ;;
    "check")
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 check <base_id> <count>"
            exit 1
        fi
        check_containers $2 $3
        ;;
    "cleanup")
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 cleanup <base_id> <count>"
            exit 1
        fi
        cleanup_containers $2 $3
        ;;
    *)
        echo "Usage:"
        echo "  $0 create <ct_id> <hostname> <ip>"
        echo "  $0 deploy-cluster <base_id> <count> <base_ip>"
        echo "  $0 check <base_id> <count>"
        echo "  $0 cleanup <base_id> <count>"
        echo ""
        echo "Examples:"
        echo "  $0 create 100 nixos-test 192.168.0.100/24"
        echo "  $0 deploy-cluster 100 3 192.168.0.100/24"
        echo "  $0 check 100 3"
        echo "  $0 cleanup 100 3"
        exit 1
        ;;
esac
