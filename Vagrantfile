VM_NAME = ENV['VM_NAME'] || "default-hyperv-vm"
VM_MEM  = ENV['VM_MEMORY'] || "2048"
VM_CPUS = ENV['VM_CPUS'] || "2"
VM_IP   = ENV['VM_IP'] || "192.168.0.10"
VM_GW   = "192.168.0.1"

Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
  config.vm.hostname = VM_NAME

  config.vm.provider "hyperv" do |hv|
    hv.cpus = VM_CPUS.to_i
    hv.memory = VM_MEM.to_i # In MB
    hv.vmname = VM_NAME
  end

  config.vm.network "private_network", bridge: "VMSwitchNat"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Questo script viene eseguito come root dentro la VM al primo avvio
  config.vm.provision "shell", inline: <<-SHELL
    set -eux

    echo "=== Configurazione tastiera ==="
    if [ -f /etc/default/keyboard ]; then
      sed -i 's/XKBLAYOUT=.*/XKBLAYOUT="it"/' /etc/default/keyboard || true
      setupcon --force || true
    fi

    echo "=== Configurazione SSH ==="
    systemctl enable ssh
    systemctl restart ssh

    echo "=== Interfacce rilevate ==="
    ip -br addr

    # Hyper-V normalmente espone una sola NIC
    IFACE=$(ip -o link show \
      | awk -F': ' '{print $2}' \
      | grep -v '^lo$' \
      | head -n1)

    if [ -z "$IFACE" ]; then
      echo "ERRORE: nessuna interfaccia trovata"
      exit 1
    fi

    echo "Interfaccia selezionata: $IFACE"

    cat >/etc/netplan/60-vagrant-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - #{VM_IP}/24
      routes:
        - to: default
          via: #{VM_GW}
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
      optional: true
NETPLAN

    chmod 600 /etc/netplan/60-vagrant-static.yaml

    echo "=== Netplan generato ==="
    cat /etc/netplan/60-vagrant-static.yaml
    netplan generate
    netplan apply

    echo "=== Disable network boot waiting ==="
    systemctl disable systemd-networkd-wait-online.service || true
    systemctl mask systemd-networkd-wait-online.service || true

    echo "=== Configurazione finale ==="
    ip -br addr
    ip route
  SHELL
end