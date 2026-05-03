#!/usr/bin/env bash
set -e

WG_IF=wg0
WG_NET=10.10.1.0/24

# Удаляем правила
iptables -D FORWARD -i $WG_IF -j ACCEPT
iptables -D FORWARD -o $WG_IF -j ACCEPT

iptables -t nat -D POSTROUTING -s $WG_NET -j MASQUERADE

# Всякая DNAT
iptables -t nat -F PREROUTING -i $WG_IF
