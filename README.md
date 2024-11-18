# nixos-deploy
Deploy NixOS in PVE

### Create CT with ID 120
`bash deploy_lxc.sh create 120 nixos 192.168.0.198/24 192.168.0.1`

### Enter in CT
`pct exec 120 -- /run/current-system/sw/bin/bash`

### Create VM with ID 120
`bash deploy_vma.sh restore 120 nixos 192.168.0.198/24 192.168.0.1`

### Create Your Own Template

Edit vm-config.nix :

`nano vm-config.nix`

Build your Template

```
nix run github:nix-community/nixos-generators -- --format proxmox \
                  --configuration vm-config.nix
```

Upload Your Template

`/var/lib/pve/PVE_STORAGE/dump/`
