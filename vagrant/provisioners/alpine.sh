#!/bin/sh
set -eux

VM_IP=$1
VM_GW=$2

echo "=== Configurazione SSH ==="
rc-update add sshd default
rc-service sshd restart

echo "=== Interfacce rilevate ==="
ip -br addr

IFACE=$(ip -o link show \
    | awk -F': ' '$2 != "lo" {print $2; exit}')
if [ -z "$IFACE" ]; then
    echo "ERRORE: nessuna interfaccia trovata"
    exit 1
fi

echo "Interfaccia selezionata: $IFACE"

echo "=== Configurazione rete con OpenRC ==="
cat >/etc/network/interfaces <<INTERFACES
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet static
    address $VM_IP
    netmask 255.255.255.0
    gateway $VM_GW
INTERFACES
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
rc-update add networking boot
rc-service networking restart