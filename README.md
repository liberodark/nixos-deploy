# nixos-deploy
Deploy NixOS in PVE

### Create CT with ID 120
`bash deploy_lxc.sh create 120 nixos 192.168.0.198/24 192.168.0.1`

### Enter in CT
`pct exec 120 -- /run/current-system/sw/bin/bash`
