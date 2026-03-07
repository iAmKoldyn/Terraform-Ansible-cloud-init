version: 2
ethernets:
  __HOSTONLY_IF__:
    dhcp4: false
    optional: true
    addresses:
      - __NODE_IP__/__PREFIX_LENGTH__
  __NAT_IF__:
    dhcp4: true
    optional: true
