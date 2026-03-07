#cloud-config
package_update: false
package_upgrade: false

users:
  - default
  - name: naurlox
    lock_passwd: true
    gecos: Cluster Admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups:
      - sudo
    ssh_authorized_keys:
      - __SSH_PUBLIC_KEY__

ssh_pwauth: false
disable_root: true
ssh_deletekeys: true

bootcmd:
  - [bash, -lc, "systemctl stop --no-block apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true"]
  - [bash, -lc, "systemctl disable --now apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true"]
  - [bash, -lc, "systemctl mask apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true"]

write_files:
  - path: /etc/ssh/sshd_config.d/50-cloud-init.conf
    owner: root:root
    permissions: "0600"
    content: |
      PasswordAuthentication no
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    owner: root:root
    permissions: "0644"
    content: |
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      PubkeyAuthentication yes
      PermitRootLogin no

runcmd:
  - [bash, -lc, "rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg || true"]
  - [bash, -lc, "rm -f /etc/netplan/*.yaml || true"]
  - [bash, -lc, "printf 'network:\n  version: 2\n  ethernets:\n    __HOSTONLY_IF__:\n      dhcp4: false\n      optional: true\n      addresses:\n        - __NODE_IP__/__PREFIX_LENGTH__\n    __NAT_IF__:\n      dhcp4: true\n      optional: true\n' > /etc/netplan/60-kp-static.yaml && chmod 600 /etc/netplan/60-kp-static.yaml"]
  - [bash, -lc, "netplan generate && netplan apply || true"]
  - [bash, -lc, "systemctl disable --now systemd-networkd-wait-online.service NetworkManager-wait-online.service 2>/dev/null || true"]
  - [bash, -lc, "ssh-keygen -A || true"]
  - [bash, -lc, "printf 'PasswordAuthentication no\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf"]
  - [bash, -lc, "systemctl restart ssh || systemctl restart sshd || true"]
