#!/bin/bash

# =================配置区域=================
# 请根据你的实际情况修改接口名称
WAN_IF="eth1" # WAN 口
LAN_IF="eth0" # LAN 口

# LAN 口网络配置
LAN_IP="10.0.0.1"
LAN_NETMASK="24"

# DHCP 配置
DHCP_START="10.0.0.3"
DHCP_END="10.0.0.150"
DHCP_LEASE="12h"

# 下发给客户端的 DNS (DHCP Option 6)
# 如果你马上要部署 dae/sing-box，通常指向网关IP(本机)由它们劫持
# 如果只是想先通网，可以填 223.5.5.5
CLIENT_DNS="${LAN_IP}"
# =========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 (保留 systemd-resolved 模式) ===${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 运行此脚本!${NC}"
  exit 1
fi

# 1. 安装软件
echo -e "${GREEN}[1/5] 安装依赖 (nftables, dnsmasq)...${NC}"
apt update
apt install -y nftables dnsmasq

# 2. 配置网络接口 (Netplan)
echo -e "${GREEN}[2/5] 配置网络接口...${NC}"
if [ -d /etc/netplan ]; then
  mkdir -p /etc/netplan/backup
  mv /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
fi

cat <<EOF >/etc/netplan/01-router-config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: true
      optional: true
    ${LAN_IF}:
      dhcp4: false
      addresses:
        - ${LAN_IP}/${LAN_NETMASK}
EOF

# 3. 开启内核转发
echo -e "${GREEN}[3/5] 开启 IP 转发...${NC}"
cat <<EOF >/etc/sysctl.d/99-router-forward.conf
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-router-forward.conf

# 4. 配置 Nftables NAT
echo -e "${GREEN}[4/5] 配置 Nftables NAT...${NC}"
cat <<EOF >/etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "${WAN_IF}" masquerade
    }
}

table inet filter {
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        iifname "${LAN_IF}" accept
    }
    chain input {
        type filter hook input priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

systemctl enable nftables
systemctl restart nftables

# 5. 配置 Dnsmasq (纯 DHCP 模式)
echo -e "${GREEN}[5/5] 配置 Dnsmasq (DHCP Only)...${NC}"

# 仅停用 NetworkManager，保留 systemd-resolved
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true

cat <<EOF >/etc/dnsmasq.conf
# === 核心设置 ===
# 禁用 DNS 功能，只提供 DHCP
# 这避免了与 systemd-resolved (端口53) 的冲突
port=0

# 监听接口
interface=${LAN_IF}

# === DHCP 设置 ===
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=3,${LAN_IP}   # 网关

# 下发给客户端的 DNS 地址
# 即使 dnsmasq 不跑 DNS，我们也要告诉客户端去哪里解析
# 如果你后续跑 dae，客户端请求发给网关，dae 会在网关劫持
dhcp-option=6,${CLIENT_DNS}

bind-interfaces
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

# 应用网络
netplan apply

echo -e "${GREEN}=== 部署完成! ===${NC}"
echo "Dnsmasq 运行在纯 DHCP 模式 (port=0)。"
echo "DNS 解析保留由 systemd-resolved 处理。"
