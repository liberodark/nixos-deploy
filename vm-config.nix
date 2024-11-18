{ modulesPath, config, pkgs, ... }:
{
 
  proxmox = {
    qemuConf = {
      cores = 2;
      memory = 2048;
      scsihw = "virtio-scsi-single";
      net0 = "virtio=00:00:00:00:00:00,bridge=vmbr0";
    };
    cloudInit.enable = true;
  };

  # Disable swap
  swapDevices = [];

  # Network configuration for cloud-init
  networking = {
    hostName = "";  # Set by cloud-init
    dhcpcd.enable = false;
    enableIPv6 = false;
    useHostResolvConf = false;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.nixos = {
    isNormalUser = true;
    name = "nixos";
    description = "nixos";
    initialPassword = "nixos";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  # Basic services
  services = {
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = true;
      };
    };
    qemuGuest.enable = true;
    cloud-init = {
      enable = true;
      network.enable = true;
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
