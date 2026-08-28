package main

const vagrantfileTemplate = `VM_NAME = ENV['VM_NAME']
VM_MEM = ENV['VM_MEMORY']
VM_MAX_MEM = ENV['VM_MAX_MEMORY']
VM_CPUS = ENV['VM_CPUS']
VM_IP = ENV['VM_IP']
VM_BOX = ENV['VM_BOX']
VM_BOX_VERSION = ENV['VM_BOX_VERSION']
VM_BOX_ARCHITECTURE = ENV['VM_BOX_ARCHITECTURE']
VM_GW = ENV['VM_GATEWAY']
VM_SWITCH = ENV['VM_SWITCH']
VM_PROVISIONER = ENV['VM_PROVISIONER']
VM_IP_TIMEOUT = ENV['VM_IP_TIMEOUT'].to_i

unless %w[debian ubuntu].include?(VM_PROVISIONER)
  raise "VM_PROVISIONER non supportato: #{VM_PROVISIONER}"
end

Vagrant.configure("2") do |config|
  config.vm.box = VM_BOX
  config.vm.box_version = VM_BOX_VERSION unless VM_BOX_VERSION.empty?
  config.vm.box_architecture = VM_BOX_ARCHITECTURE
  config.vm.hostname = VM_NAME
  config.vm.provider "hyperv" do |hv|
    hv.cpus = VM_CPUS.to_i
    hv.memory = VM_MEM.to_i
    hv.maxmemory = VM_MAX_MEM.to_i
    hv.vmname = VM_NAME
    hv.ip_address_timeout = VM_IP_TIMEOUT
  end
  config.vm.network "private_network", bridge: VM_SWITCH
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.provision "shell", path: "provisioners/#{VM_PROVISIONER}.sh", args: [VM_IP, VM_GW]
end
`

const ubuntuProvisioner = `#!/bin/sh
set -eux
VM_IP=$1
VM_GW=$2
if [ -f /etc/default/keyboard ]; then
    sed -i 's/XKBLAYOUT=.*/XKBLAYOUT="it"/' /etc/default/keyboard || true
    setupcon --force || true
fi
systemctl enable ssh
systemctl restart ssh
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1)
[ -n "$IFACE" ] || { echo "ERRORE: nessuna interfaccia trovata"; exit 1; }
cat >/etc/netplan/60-vagrant-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - $VM_IP/24
      routes:
        - to: default
          via: $VM_GW
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
      optional: true
NETPLAN
chmod 600 /etc/netplan/60-vagrant-static.yaml
netplan generate
netplan apply
systemctl disable systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd-wait-online.service || true
`

const debianProvisioner = `#!/bin/sh
set -eux
VM_IP=$1
VM_GW=$2
if [ -f /etc/default/keyboard ]; then
    sed -i 's/XKBLAYOUT=.*/XKBLAYOUT="it"/' /etc/default/keyboard || true
    setupcon --force || true
fi
systemctl enable ssh
systemctl restart ssh
IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
[ -n "$IFACE" ] || { echo "ERRORE: nessuna interfaccia trovata"; exit 1; }
cat >/etc/systemd/network/20-vagrant-static.network <<NETWORKD
[Match]
Name=$IFACE

[Network]
Address=$VM_IP/24
Gateway=$VM_GW
DNS=1.1.1.1
DNS=8.8.8.8
NETWORKD
systemctl restart systemd-networkd
`
