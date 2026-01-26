#!/usr/bin/bash

# ============变量配置区域==============
# armbian 是end0(wan)和enp1s0(lan)
#请根据实际情况修改接口名称,通过ip a可以查看
WAN_IF="end0" 
LAN_IF="enp1s0" 

LAN_IP="10.0.0.1"
LAN_NETMASK="24"

DHCP_START="10.0.0.3"
DHCP_END="10.0.0.150"
DHCP_LEASE="12h"

# 下发给客户端的 DNS (DHCP Option 6)
CLIENT_DNS="${LAN_IP}"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 ===${NC}"

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
      ignore-carrier: true
      addresses:
        - ${LAN_IP}/${LAN_NETMASK}
EOF
#WARNING **: 23:00:14.315: Permissions for /etc/netplan/01-router-config.yaml are too open. Netplan configuration should NOT be accessible by others.
#netplan config权限要600
chmod 600 /etc/netplan/01-router-config.yaml
netplan apply

# 3. 开启内核ipv4转发
echo -e "${GREEN}[3/5] 开启 IP 转发...${NC}"
cat <<EOF >/etc/sysctl.d/99-router-forward.conf
net.ipv4.ip_forward=1 
EOF
sysctl -p /etc/sysctl.d/99-router-forward.conf

# 4. 配置NAT
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
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
systemctl disable --now systemd-resolved 2>/dev/null || true
sudo rm /etc/resolv.conf 2>/dev/null || true

# 5. 配置 Dnsmasq 
echo -e "${GREEN}[5/5] 配置 Dnsmasq (DHCP Only)...${NC}"

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true

cat <<EOF >/etc/dnsmasq.conf
# 监听接口
interface="enp1s0"
bind-interfaces
no-resolv
server=223.5.5.5
server=223.6.6.6

domain=lan
local=/lan/
expand-hosts

dhcp-authoritative

dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}

#3是gateway,6是dns
dhcp-option=3,10.0.0.1   
dhcp-option=6,10.0.0.1
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

cat <<'EOF' | tee /etc/resolv.conf 
nameserver 127.0.0.1
options edns0 trust-ad
EOF

echo -e "${GREEN}=== 部署完成! ===${NC}"