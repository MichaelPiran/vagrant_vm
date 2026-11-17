#!/bin/sh
set -eux

VM_IP=$1
VM_GW=$2

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

IFACE=$(ip -o link show \
    | awk -F': ' '$2 != "lo" {print $2; exit}')
if [ -z "$IFACE" ]; then
    echo "ERRORE: nessuna interfaccia trovata"
    exit 1
fi

echo "Interfaccia selezionata: $IFACE"

echo "=== Configurazione rete con systemd-networkd ==="
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