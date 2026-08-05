# NN6000 V1 无WiFi版 固件编译 (OpenWRT / ImmortalWrt)

> ⚠️ **警告：本仓库仅为作者个人使用的固件编译配置，不适合他人直接使用。**
> 
> 本仓库包含作者私人定制的网络参数、MAC 地址、root 密码、IPTV 配置等，直接使用本仓库编译的固件可能导致您的设备无法正常工作、网络冲突或安全风险。
> 
> **仅供学习参考，请勿下载使用本仓库的 Release 固件。**

---

# 编译源

ImmortalWrt 官方版：
https://github.com/immortalwrt/immortalwrt.git

VIKINGYFY 自用版（默认使用）：
https://github.com/VIKINGYFY/immortalwrt.git

---

# 仅个人使用声明

本仓库所有配置文件、脚本、固件 Release 均为作者私人定制，**包含以下个人专属配置**：

- 静态 IP 地址、网关、DNS 服务器
- 自定义 MAC 地址（lan1/lan2/lan3）
- root 用户密码
- IPTV 专用网口配置（lan3 分离）
- rtp2httpd 服务配置和频道列表
- 防火墙 zone 规则
- 其他与作者网络环境绑定的参数

**他人请勿使用本仓库的 Release 固件，否则后果自负。**
