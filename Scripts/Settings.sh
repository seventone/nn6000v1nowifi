#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 旁路由专用版：NN6000 V1 无WiFi版
# 目标：
#   - 仅单臂旁路由模式（所有物理口均为 LAN，桥接 br-lan）
#   - 静态 IP：10.0.0.30/24，网关 10.0.0.100，DNS 10.0.0.5 + 223.5.5.5
#   - 关闭 DHCP（主路由提供 DHCP）
#   - 删除 WAN/WAN6 接口 + 防火墙 WAN zone
#   - IPv6 编译进固件但默认关闭
#   - 物理网口重新编号：原WAN→lan1，原LAN1→lan2，原LAN2→lan3，全部桥接
#   - 默认主题 Argon，默认主机名 NN6000

# ===== 旁路由网络参数（按需修改） =====
LAN_IP="10.0.0.30"
LAN_MASK="255.255.255.0"
LAN_GW="10.0.0.100"
LAN_DNS1="10.0.0.5"
LAN_DNS2="223.5.5.5"

# ========================================================================
# 1. 通用默认值修改（原脚本保留的必要逻辑）
# ========================================================================

# 移除 luci-app-attendedsysupgrade（避免 make defconfig 时被选入）
ATHD_MAKEFILES=$(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$ATHD_MAKEFILES" ]; then
	sed -i "/attendedsysupgrade/d" $ATHD_MAKEFILES
fi

# 修改默认主题为 Argon（feeds/luci/collections 下的 Makefile 指定了默认主题）
LUCICOLL_MAKEFILES=$(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$LUCICOLL_MAKEFILES" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $LUCICOLL_MAKEFILES
fi

# 修改 immortalwrt.lan 关联 IP 显示（在 flash.js 中显示的提示 IP）
FLSH_JS=$(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null)
if [ -n "$FLSH_JS" ]; then
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$LAN_IP/g" $FLSH_JS
fi

# 添加编译日期标识（Status 页面 10_system.js 中的系统时间行后面加编译日期标记）
SYS_JS=$(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" 2>/dev/null)
if [ -n "$SYS_JS" ] && [ -n "${WRT_MARK:-}" ] && [ -n "${WRT_DATE:-}" ]; then
	sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $SYS_JS
fi

# WIFI 相关（无 WiFi 版：若找到无线设置脚本则按传入参数替换，否则跳过，不影响）
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

# 修改默认 IP / 主机名（先改基础模板，后面 uci-defaults 会再覆盖为旁路由专用值，双重保险）
CFG_FILE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$LAN_IP/g" $CFG_FILE
	sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
fi

# 基础配置注入
# LuCI 元包 + 简体中文语言包（关键：CONFIG_LUCI_LANG_zh_Hans=y 是 LuCI 中文总开关，
# 开启后会自动把所有 luci 模块的中文翻译编进固件，否则默认只有英文）
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

# 引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

# 手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

# 无 WiFi 配置标志（沿用原脚本）
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

# 高通平台 nowifi DTS 调整（沿用原脚本）
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} + 2>/dev/null
		echo "qualcommax nowifi DTS reference setup done!"
	fi
fi

# ========================================================================
# 2. NN6000 V1 网口重定义（patch ImmortalWrt 源码）
#    目标：所有口均为 LAN，桥接 br-lan
#    label 映射：原 WAN 口 -> lan1，原 LAN1 口 -> lan2，原 LAN2 口 -> lan3
# ========================================================================

BOARD_D_NET="./target/linux/qualcommax/ipq60xx/base-files/etc/board.d/02_network"
if [ -f "$BOARD_D_NET" ] && grep -q "link_nn6000-v1" "$BOARD_D_NET"; then
	#
	# 在 board.d/02_network 中，设备 link_nn6000-v1 会有类似：
	#   ucidef_set_interfaces_lan_wan "lan1 lan2" "wan"
	# 我们把它改为全部三个口都放在 lan 组，没有 wan
	#
	sed -i '/link_nn6000-v1/,/;;/ {
		s/ucidef_set_interfaces_lan_wan\s\+"[^"]*"\s\+"[^"]*"/ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" ""/g
	}' "$BOARD_D_NET" 2>/dev/null

	echo "NN6000 V1: board.d/02_network patched: no WAN, all ports to LAN group."
fi

#
# Patch DTS：link_nn6000-v1 的三个以太网端口 label 统一改为 lan1/lan2/lan3
# 按用户要求：物理口原WAN(通常是 label="WAN")→lan1，原LAN1→lan2，原LAN2→lan3
#
NN6000_DTS=$(find ./target/linux/qualcommax/dts/ -maxdepth 2 -type f \( -iname "*link*nn6000*v1*.dts" -o -iname "*nn6000*v1*.dts" -o -iname "*qcom-ipq6018-link-nn6000-v1.dts*" \) 2>/dev/null | head -n 1)

if [ -n "$NN6000_DTS" ]; then
	echo "NN6000 V1 DTS found: $NN6000_DTS — renaming port labels."
	#
	# 策略（防止顺序连锁覆盖）：先改高编号 → 再改低编号
	#   1) 先把原 LAN2 改为 lan3（不影响 WAN/LAN1）
	#   2) 再把原 LAN1 改为 lan2（不影响 WAN/lan3）
	#   3) 最后把原 WAN 改为 lan1（不影响 lan2/lan3）
	# 每次替换都用 '0,/pattern/s//replacement/' 只改第一个匹配项，DTS 大小写不固定，所以都判断。
	#
	# Step 1: LAN2 / lan2 → lan3（只改第一个匹配）
	if grep -qi 'label\s*=\s*"LAN2"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"LAN2"/I s//label = "lan3"/' "$NN6000_DTS"
	elif grep -q 'label\s*=\s*"lan2"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"lan2"/ s//label = "lan3"/' "$NN6000_DTS"
	fi
	# Step 2: LAN1 / lan1 → lan2（只改第一个匹配）
	if grep -qi 'label\s*=\s*"LAN1"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"LAN1"/I s//label = "lan2"/' "$NN6000_DTS"
	elif grep -q 'label\s*=\s*"lan1"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"lan1"/ s//label = "lan2"/' "$NN6000_DTS"
	fi
	# Step 3: WAN / wan → lan1（只改第一个匹配）
	if grep -qi 'label\s*=\s*"WAN"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"WAN"/I s//label = "lan1"/' "$NN6000_DTS"
	elif grep -q 'label\s*=\s*"wan"' "$NN6000_DTS"; then
		sed -i '0,/label\s*=\s*"wan"/ s//label = "lan1"/' "$NN6000_DTS"
	fi

	echo "NN6000 V1 DTS port labels remapped (WAN→lan1, LAN1→lan2, LAN2→lan3)."
fi

# ========================================================================
# 3. 创建旁路由专用 uci-defaults 脚本（首次启动自动执行）
#    - 静态 IP / 网关 / DNS
#    - 删除 WAN/WAN6 接口
#    - DHCP 关闭
#    - IPv6 默认关闭
#    - 防火墙删除 WAN zone
# ========================================================================

UCI_DEFAULTS_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"

cat > "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi" <<'UCI_EOF'
#!/bin/sh
# NN6000 V1 无WiFi版 —— 旁路由专用默认配置
# 首次启动自动执行，仅运行一次

# ---------- 1. 删除 WAN / WAN6 接口，仅保留 LAN ----------
uci delete network.wan 2>/dev/null
uci delete network.wan6 2>/dev/null
uci delete network.wan_dev 2>/dev/null
uci delete network.wan6_dev 2>/dev/null

# 所有物理口已通过 board.d+DTS patch 进 LAN bridge (br-lan)，无需单独配置。

# ---------- 2. LAN 静态 IP / 掩码 / 网关 / DNS ----------
LAN_IP="PLACEHOLDER_LAN_IP"
LAN_MASK="PLACEHOLDER_LAN_MASK"
LAN_GW="PLACEHOLDER_LAN_GW"
LAN_DNS1="PLACEHOLDER_LAN_DNS1"
LAN_DNS2="PLACEHOLDER_LAN_DNS2"

uci set network.lan.proto='static'
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_MASK"
uci set network.lan.gateway="$LAN_GW"
uci set network.lan.dns="$LAN_DNS1 $LAN_DNS2"
# 旁路由模式：LAN 接口强制桥接，不要 delegate IPv6
uci set network.lan.delegate='0'
uci delete network.lan.ip6assign 2>/dev/null
uci delete network.lan.ip6hint 2>/dev/null

# ---------- 3. 关闭 DHCP（旁路由模式由主路由提供 DHCP） ----------
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.start='' 2>/dev/null
uci set dhcp.lan.limit='' 2>/dev/null
uci set dhcp.lan.leasetime='' 2>/dev/null
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ra_flags='none'
# odhcpd 整体禁用（避免意外发 RA）
uci set dhcp.odhcpd.maindhcp='0' 2>/dev/null
/etc/init.d/odhcpd disable 2>/dev/null

# ---------- 4. IPv6 默认关闭（内核模块保留，用户需要时手动开启） ----------
uci set network.globals.ula_prefix='' 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
echo "net.ipv6.conf.all.disable_ipv6 = 1"  >> /etc/sysctl.conf 2>/dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf 2>/dev/null

# ---------- 5. 防火墙：删除 WAN zone 及相关 forwarding，仅保留 LAN ----------
# 删除所有 wan 相关 zone
while uci -q delete firewall.@zone[0]; do :; done 2>/dev/null
# 重新添加一个只有 LAN 的 zone（允许转发，允许 input/output）
uci add firewall zone
uci set firewall.@zone[-1].name='lan'
uci set firewall.@zone[-1].network='lan'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='0'
uci set firewall.@zone[-1].mtu_fix='0'
# forwarding 规则清零（旁路由不需要 WAN↔LAN 转发）
while uci -q delete firewall.@forwarding[0]; do :; done 2>/dev/null

# ---------- 6. 提交所有 uci 变更 ----------
uci commit network
uci commit dhcp
uci commit firewall

# ---------- 7. 写死 /etc/resolv.conf 避免被覆盖（旁路由模式下的 DNS） ----------
cat > /etc/resolv.conf <<RESOLV_EOF
nameserver PLACEHOLDER_LAN_DNS1
nameserver PLACEHOLDER_LAN_DNS2
RESOLV_EOF
chmod 0644 /etc/resolv.conf 2>/dev/null

exit 0
UCI_EOF
chmod +x "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"

# 用实际参数替换占位符
sed -i "s|PLACEHOLDER_LAN_IP|$LAN_IP|g"       "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_MASK|$LAN_MASK|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_GW|$LAN_GW|g"       "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_DNS1|$LAN_DNS1|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_DNS2|$LAN_DNS2|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"

echo "NN6000 V1 旁路由 uci-defaults 已注入：IP=$LAN_IP GW=$LAN_GW DNS=$LAN_DNS1,$LAN_DNS2 DHCP=off IPv6=default-off"
echo "所有物理口重映射到 br-lan，网口 label：WAN→lan1 / LAN1→lan2 / LAN2→lan3"
