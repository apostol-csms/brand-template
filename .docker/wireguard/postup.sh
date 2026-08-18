#!/bin/sh

WIREGUARD_INTERFACE=wg0
WIREGUARD_LAN=10.10.1.0/24
DOCKER_LAN=172.18.0.0/16   # covers 172.18.0.0/24, 172.18.1.0/24, 172.18.2.0/24

# Allow forwarding both ways through wg0
iptables -A FORWARD -i $WIREGUARD_INTERFACE -j ACCEPT
iptables -A FORWARD -o $WIREGUARD_INTERFACE -j ACCEPT

# NAT from WG into Docker, so packets from 10.0.0.x to 172.18.x.x look local
iptables -t nat -A POSTROUTING -s $WIREGUARD_LAN -d $DOCKER_LAN -j MASQUERADE

# NAT from Docker into WG, for containers reaching out to 10.0.0.x
iptables -t nat -A POSTROUTING -s $DOCKER_LAN -o $WIREGUARD_INTERFACE -j MASQUERADE
