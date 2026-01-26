#!/bin/env bash
# Zsh 安装脚本
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 运行此脚本!"
  exit 1
fi
apt update
apt install -y zsh git
chsh -s $(which zsh) $(logname)
echo "Zsh 已安装并设置为默认 shell。请重新登录以应用更改。"
#ohmyzsh 安装
sudo -u $(logname) sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
echo "Oh My Zsh 已安装。"