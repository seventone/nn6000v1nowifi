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
if [ -f "$BOARD_D_NET" ] && grep -q "link,nn6000-v1" "$BOARD_D_NET"; then
	#
	# 在 board.d/02_network 中，设备 link,nn6000-v1 的 case 分支原文：
	#   link,nn6000-v1)
	#       ucidef_set_interfaces_lan_wan "lan1 lan2" "wan"
	#       ;;
	# 我们在这个独立的 case 范围内，把包含 ucidef_set_interfaces_lan_wan 的整行
	# 直接替换为 3 个口全部 LAN + 无 WAN，这样 netifd 启动时会把 lan1/lan2/lan3
	# 全部自动桥接到 br-lan。
	#
	# 范围用 /link,nn6000-v1)/,/;;/ 精确锁到 nn6000 这一个设备分支，
	# 不会误伤 dptech,ap3000-2c / 8devices,mango-dvk / glinet,gl-axt1800
	# 等其它和 nn6000 共用同一条配置的设备（之前方案1就是因为没加范围，
	# 全局替换导致编译异常）。
	#
	sed -i '/link,nn6000-v1)/,/;;/ {
		s/.*ucidef_set_interfaces_lan_wan.*/\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" ""/
	}' "$BOARD_D_NET" 2>/dev/null

	echo "NN6000 V1: board.d/02_network patched: no WAN, all 3 ports to LAN group."
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

	# ===== 方案A：把 MAC 地址写进 DTS 节点 =====
	# 目标：驱动 probe 时直接从 DTS 读取 mac-address / local-mac-address，
	# 这样就不需要为 lan1/lan2/lan3 单独创建 UCI「匿名 device section」
	# 来写 macaddr —— 避免 LuCI 设备页同时列"内核裸口 + UCI device 段"两份，
	# 导致每个口显示两次。
	#
	# MAC 字节数组（用户指定）：
	#   lan1 = f8:5e:3c:4c:50:7a  -> 0xF8 0x5E 0x3C 0x4C 0x50 0x7A
	#   lan2 = f8:5e:3c:4c:50:7b  -> 0xF8 0x5E 0x3C 0x4C 0x50 0x7B
	#   lan3 = f8:5e:3c:4c:50:7c  -> 0xF8 0x5E 0x3C 0x4C 0x50 0x7C
	#
	# 匹配每个 dp2/dp3/dp4 节点（对应 label=lan1/lan2/lan3），在其节点末尾
	# （也就是最近的一个 }; 闭合之前）追加 mac-address 和 local-mac-address 两
	# 行属性。对同一个节点，若已经写过就不再追加（用 grep 做判重）。
	_INSERT_DTS_MAC() {
		# 参数 1: label 名字 (lan1/lan2/lan3)；参数 2: DTS 字节串
		_label="$1"; _bytes="$2"
		# 找到包含 label="$_label" 的 dp 节点的起始行号
		_start=$(awk -v lbl="$_label" '$0 ~ "label\\s*=\\s*\""lbl"\"" {print NR; exit}' "$NN6000_DTS")
		if [ -z "$_start" ]; then
			echo "  [WARN] DTS label=$_label 节点没找到，跳过 MAC 写入"
			return 0
		fi
		# 从 $_start 开始往后，找到该节点的第一个 }; 闭合行号
		_end=$(awk -v s="$_start" 'NR>s && /^[[:space:]]*\};[[:space:]]*$/ {print NR; exit}' "$NN6000_DTS")
		if [ -z "$_end" ]; then
			echo "  [WARN] DTS label=$_label 节点闭合没找到，跳过 MAC 写入"
			return 0
		fi
		# 如果这个范围内已经有 mac-address 属性了就不再加（防重复）
		if sed -n "${_start},${_end}p" "$NN6000_DTS" | grep -q 'mac-address'; then
			echo "  DTS label=$_label: 已有 mac-address 节点，跳过"
			return 0
		fi
		# 在第 $_end 行之前插入两行 mac-address 和 local-mac-address
		_pad=""
		# 取闭合行 }; 前面的缩进数作为新行的缩进
		_pad=$(sed -n "${_end}p" "$NN6000_DTS" | sed -n 's/\([[:space:]]*\)\};.*/\1/p')
		# 若取不出缩进，默认两个 tab
		[ -z "$_pad" ] && _pad=$(printf '\t\t')
		# 写入
		sed -i "${_end}i\\
${_pad}mac-address = [$_bytes];\\
${_pad}local-mac-address = [$_bytes];" "$NN6000_DTS"
		echo "  DTS label=$_label: 写入 mac-address = $_bytes OK"
	}
	_INSERT_DTS_MAC "lan1" "f8 5e 3c 4c 50 7a"
	_INSERT_DTS_MAC "lan2" "f8 5e 3c 4c 50 7b"
	_INSERT_DTS_MAC "lan3" "f8 5e 3c 4c 50 7c"
	unset -f _INSERT_DTS_MAC

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

# ---------- 2. 自定义 MAC 地址 + br-lan 网桥 MAC 跟随（方案 A） ----------
# 用户指定：lan1=f8:5e:3c:4c:50:7a  lan2=f8:5e:3c:4c:50:7b  lan3=f8:5e:3c:4c:50:7c
#           br-lan=跟随 lan1=f8:5e:3c:4c:50:7a
# 实现方式（方案 A，解决 LuCI 设备页「每个物理口显示两次」问题）：
#   1) 物理口 MAC 已经在 Settings.sh 的 DTS patch 阶段写进 DTS 节点的
#      mac-address / local-mac-address 属性（驱动 probe 时直接读），
#      所以 **这里完全不为 lan1/lan2/lan3 单独创建 UCI device section**，
#      否则 LuCI 设备页会同时列「内核裸口（来自 DTS）+ UCI device 段」
#      两份，每个口显示两次。
#   2) br-lan 网桥 MAC 仍通过 UCI 匿名 section 写死（网桥驱动不会从 DTS
#      读 MAC，需要显式指定），只改 board.d 已经生成的那个 section，
#      绝对不新建第二个名为 br-lan 的 device。
#   3) 再加一层「首次启动 ip link set address」兜底：万一上游某一版
#      NSS-DP 驱动暂时忽略了 DTS 里的 mac-address，这里再手动刷一遍
#      保证 MAC 仍是用户指定的。
# 合法性：
#   第 1 字节 0xf8=1111_1000，最低位=0（合法单播）；
#   前 5 字节 f8:5e:3c:4c:50 与原厂 OUI 对齐；
#   三个口最后 1 字节 7a/7b/7c，与原厂 79/7a/7b 错开不冲突。
LAN1_MAC='f8:5e:3c:4c:50:7a'
LAN2_MAC='f8:5e:3c:4c:50:7b'
LAN3_MAC='f8:5e:3c:4c:50:7c'
BR_LAN_MAC=$LAN1_MAC

# ---------- 2.1 ~ 2.2 device section：暴力清空 + 原子重建（绝对只有1个） ----------
# 背景（backup-v4 / v4.1 实测的坑）：
#   不管怎么写"遍历索引 + 按 name 分类删"，真实设备首次启动后
#   `uci show network | grep -c @device` 仍会稳定地 = 5（1 个 br-lan + 4 个
#   "没有 name 字段的空壳匿名 device section"）。经过两轮排查确认：
#     ① 用 `uci -q show @device[N]` 当 while 条件在某些 uci/libuci 版本
#        上对"完全空、连 type 字段都没有"的匿名 section exit code 不可靠；
#     ② board.d / 02_network / netifd 自身在首次启动某个时序里可能额外
#        调用 `uci add network device` 但忘了 `uci set .name`，留下裸空壳。
#   既然"删不干净"，干脆"扫光重建"——只要我们 100% 控制最终有几个匿名
#   device section，就永远不会有 LuCI 设备页多显示的问题。
#
# 新策略（backup-v4.2 及以后，推荐，永远生效）：
#   Step A：删干净所有命名 device section（lan1/2/3 + br_lan 这种显式名）
#   Step B：无限删 `network.@device[0]`，只要索引 0 上还有匿名 section 就
#           一直删，最终 UCI 里一个匿名 device 都不剩。
#           → 这一步是本策略的关键：**根本不需要判断每个 section 里有啥，
#             统一从 0 号下标反复删**，不会漏任何"空壳/畸形/只含 type 没 name"
#             的历史遗留。
#   Step C：`uci add network device` 明确**新建 1 个**匿名 device section
#           （它必然是新的 @device[0]）。
#   Step D：给这个新 section 一次性写齐 4 个字段：
#              type=bridge  （必须，不然 netifd 不认为它是网桥）
#              name=br-lan   （必须，和逻辑接口 network.lan.device 对应）
#              macaddr=$BR_LAN_MAC  （网桥 MAC 必须 UCI 指定，驱动不从 DTS 读）
#              ports 列表 = lan1 lan2 lan3   （add_list，避免重复）
#
# 结果：/etc/config/network 里永远只有 1 个匿名 @device[0]，
#       内容就是我们刚写的 br-lan 网桥，其他全没。
#       `uci show network | grep -c @device` 必然等于 1。

# Step A：命名 device section 清理
uci delete network.lan1 2>/dev/null || true
uci delete network.lan2 2>/dev/null || true
uci delete network.lan3 2>/dev/null || true
uci delete network.br_lan 2>/dev/null || true

# Step B：暴力清空所有匿名 device section（从 0 号反复删，直到索引 0 不存在）
# 关键：不判断内容、不递增索引、不需要每个 section 有 name/type 字段。
# 每删一次后面的 section 自动前移到 0 号位置，所以永远只要删 0 号。
while uci -q show "network.@device[0]" > /dev/null 2>&1; do
  uci -q delete "network.@device[0]" 2>/dev/null || true
done

# Step C：明确新建 1 个匿名 device section（必然是 @device[0]）
uci add network device > /dev/null

# Step D：为 @device[0] 写齐网桥 4 个字段
uci set "network.@device[0].type=bridge"
uci set "network.@device[0].name=br-lan"
# ⚠ MAC 只用一层双引号，不要再嵌套单引号（子坑 9-b 教训）：
#     错误写法 uci set "...macaddr='$BR_LAN_MAC'" → 存进去带 ' 引号 → bridge 不认
#     正确写法 uci set "...macaddr=$BR_LAN_MAC"  → 纯 MAC 字符串 → 生效
uci set "network.@device[0].macaddr=$BR_LAN_MAC"
# ports：先清后加，用 add_list，保证 lan1/2/lan3 都在、且不重复
for _p in lan1 lan2 lan3; do
  uci -q del_list "network.@device[0].ports=$_p" 2>/dev/null
  uci add_list "network.@device[0].ports=$_p" 2>/dev/null || true
done

# 确保 network.lan（逻辑接口）绑定的 device 就是 br-lan（保险写一遍）
uci set network.lan.device='br-lan'

# ---------- 2.3 兜底：首次启动立即把 3 个物理口 + 网桥刷上新 MAC ----------
# （即便 NSS-DP 驱动已经从 DTS 读到正确 MAC，再 ip link set 一次也无害；
#   如果上游某版驱动暂时忽略了 DTS mac-address，这一步就保证了。）
if [ -d /sys/class/net/lan1 ]; then
  ip link set dev lan1 address "$LAN1_MAC" 2>/dev/null || true
fi
if [ -d /sys/class/net/lan2 ]; then
  ip link set dev lan2 address "$LAN2_MAC" 2>/dev/null || true
fi
if [ -d /sys/class/net/lan3 ]; then
  ip link set dev lan3 address "$LAN3_MAC" 2>/dev/null || true
fi
if [ -d /sys/class/net/br-lan ]; then
  ip link set dev br-lan address "$BR_LAN_MAC" 2>/dev/null || true
fi

# ---------- 3. LAN 静态 IP / 掩码 / 网关 / DNS ----------
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

# ---------- 8. 清理虚拟模板接口（双保险，彻底清 dummy0/erspan0/gre0/sit0 等） ----------
# 说明：GENERAL.txt 里已经把 kmod-dummy/kmod-gre/kmod-erspan/kmod-gretap/
# kmod-ip6-tunnel/kmod-sit 都设成了 =n，理论上这些模块不编进固件，
# 开机就不会自动建模板接口。但有两种情况会导致清理第一轮不生效：
#   (1) 某模块被内核做成 built-in，开机比 99-nn6000v1nowifi 还早就建了口，
#       第一轮清理跑完，后面 systemd/sysfs 又触发一次模板接口注册；
#   (2) 用户后期 opkg install 了 openvpn/ipsec 之类的包，依赖链把 gre/ip6_tunnel
#       等 ko 拉回来，重启后模板口又冒出来（最典型就是 ip6gre0 / ip6tnl0 / sit0）。
# 所以这里做 3 层清理：
#   ① 主清理循环：清掉所有模板设备
#   ② 卸载模块（ko 形式的），从源头掐断
#   ③ 二次循环 + 短暂延迟，清掉模块卸载之后又被"系统残留事件"重新注册出来
#     的孤儿口（ip6gre0 / ip6tnl0 / sit0 最常见）
for _pass in 1 2; do
  for _dev in dummy0 erspan0 gre0 gretap0 ip6gre0 ip6tnl0 sit0; do
    if [ -d /sys/class/net/$_dev ]; then
      ip link set dev $_dev down 2>/dev/null || true
      ip link delete dev $_dev 2>/dev/null || true
    fi
  done
  # dummy 模块如果是 ko 形式加载的（不是 built-in），直接卸载掉
  rmmod dummy 2>/dev/null || true
  # gre / ip_gre / ip6_gre / ip6_tunnel / sit / gretap / erspan / ipip 同上
  for _mod in dummy gre ip_gre gretap ip6_gre ip6_tunnel sit ipip erspan; do
    rmmod $_mod 2>/dev/null || true
  done
  # 第一轮跑完短暂 sleep，给 sysfs/kobject uevent 发完事件的时间，
  # 第二轮就能把"模块卸载事件又触发模板接口重新注册"出来的孤儿口清掉。
  if [ $_pass -eq 1 ]; then
    sleep 1
  fi
done
# 收尾：再把所有可能残留的隧道 / 虚拟接口目录里的内容扫一遍
for _dev in dummy0 erspan0 gre0 gretap0 ip6gre0 ip6tnl0 sit0; do
  if [ -d /sys/class/net/$_dev ]; then
    ip link set dev $_dev down 2>/dev/null || true
    ip link delete dev $_dev nomaster 2>/dev/null || true
    ip link delete dev $_dev 2>/dev/null || true
  fi
done

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
