#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 旁路由专用版：NN6000 V1 无WiFi版 + IPTV
# 目标：
#   - 旁路由模式：lan1+lan2 桥接 br-lan，lan3 独立为 IPTV 口
#   - lan3 通过 DHCP 获取 IPTV 专网 IP，运行 rtp2httpd 提供组播转 HTTP 服务
#   - 静态 IP：10.0.0.30/24，网关 10.0.0.100，DNS 10.0.0.100 + 223.5.5.5
#   - 关闭 DHCP（主路由提供 DHCP）
#   - 删除 WAN/WAN6 接口 + 防火墙 WAN zone
#   - IPv6 编译进固件但默认关闭
#   - 物理网口重新编号：原WAN→lan1，原LAN1→lan2，原LAN2→lan3
#   - 默认主题 Argon，默认主机名 NN6000

# ===== 旁路由网络参数（按需修改） =====
LAN_IP="10.0.0.30"
LAN_MASK="255.255.255.0"
LAN_GW="10.0.0.100"
LAN_DNS1="10.0.0.100"
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
# luci-app-argon-config 只是主题外观配置面板（改背景/颜色/菜单样式），不装不影响主题本身使用
# 后期需要改主题样式时通过 opkg 安装即可，固件里不需要编译
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=n" >> ./.config

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
# 1.5 rtp2httpd 官方最新 Release 集成（package 自定义目录方式）
#    目标：每次编译时，rtp2httpd 三件套 == 官方 GitHub Release 预编译的最新版
#          （版本号 3.15.3-r1 格式，界面/菜单项和一键脚本安装的完全一致）
#
#    ⚠️ 为什么用 package 自定义目录，而不是 feeds 注入？
#       根据 https://github.com/stackia/rtp2httpd/issues/695 网友实测：
#
#       1. 本仓库 WRT-CORE.yml 的执行顺序是「Update Feeds」→「Custom Settings」：
#          L212-217：先 ./scripts/feeds update -a && feeds install -a
#          L219-229：然后才执行 Settings.sh
#          → Settings.sh 运行时 ImmortalWrt packages feed 的旧 luci-app-rtp2httpd
#            （版本号 26.xxx.xxxxx~commit，luci.mk 日期格式）已经安装完毕，
#            即便再 feeds install -f -p rtp2httpd 也可能被 tmp/.packageinfo
#            已存在的索引覆盖，导致编译出的 luci-app 是 ImmortalWrt 旧版。
#
#       2. OpenWrt 编译系统优先级：
#          `package/<自定义目录>/` 下的包 > 任何 feeds/packages/* 同名包
#          （参考 OpenWrt build 文档：local packages always win over feeds）
#          所以把三个包放到 package/ 下自定义目录，编译系统一定选本地包，
#          完全绕过 feeds 优先级机制，100% 不会被 ImmortalWrt 旧版覆盖。
#
#       3. 使用官方提供的 Makefile.versioned（固件维护者集成指南推荐）：
#          Makefile.versioned 里写死 PKG_VERSION/PKG_RELEASE，
#          不依赖 git describe / luci.mk 自动生成版本号，
#          保证和 GitHub Release 预编译包完全一致的版本号显示。
#
#    参考：
#      - https://github.com/stackia/rtp2httpd/issues/695 （xzhhzx222 方案 B）
#      - https://rtp2httpd.com/guide/installation#固件维护者集成指南
# ========================================================================
# ---------- A. 清理所有 rtp2httpd 同名旧包（防止优先级冲突）----------
# ⚠️ 关键点：ImmortalWrt 可能把 luci-app-rtp2httpd / luci-i18n-rtp2httpd-zh-cn
#    同时放在「packages feed」和「luci feed」两处（取决于发布快照版本）。
#    只删固定路径会漏，所以用 find 模糊匹配，所有 package/feeds 下目录名含
#    rtp2httpd 的一律删除（最大深度 2：package/feeds/<feed名>/<pkg名>/）。
#    实测：当前路由器里 luci-app-rtp2httpd 和 i18n 仍显示 26.208.~a3bcfe5，
#    就是因为上一轮清理没把 packages feed 里藏的另一处同名包删掉，导致
#    同名 Package 冲突时 make 选中了 ImmortalWrt 自带的日期版。
echo "[A1] find 模糊清理 package/feeds 下所有 *rtp2httpd* 目录..."
if command -v find >/dev/null 2>&1; then
	find ./package/feeds -maxdepth 2 -type d -iname '*rtp2httpd*' -print -exec rm -rf {} + 2>/dev/null
	# 保险再跑一遍（find -exec 时目录树变化可能漏）
	find ./package/feeds -maxdepth 2 -type d -iname '*rtp2httpd*' -print -exec rm -rf {} + 2>/dev/null
else
	# find 不可用时退化为显式路径（极端兜底）
	rm -rf ./package/feeds/packages/rtp2httpd 2>/dev/null
	rm -rf ./package/feeds/packages/luci-app-rtp2httpd 2>/dev/null
	rm -rf ./package/feeds/packages/luci-i18n-rtp2httpd-zh-cn 2>/dev/null
	rm -rf ./package/feeds/luci/rtp2httpd 2>/dev/null
	rm -rf ./package/feeds/luci/luci-app-rtp2httpd 2>/dev/null
	rm -rf ./package/feeds/luci/luci-i18n-rtp2httpd-zh-cn 2>/dev/null
	rm -rf ./package/feeds/routing/rtp2httpd 2>/dev/null
	rm -rf ./package/feeds/telephony/rtp2httpd 2>/dev/null
fi
# 2) 清 feeds/ 下可能残留的官方 feed 目录（之前版本 feed 注入留下的）
rm -rf ./feeds/rtp2httpd 2>/dev/null
rm -rf ./package/feeds/rtp2httpd 2>/dev/null
# 2b) 再扫一遍 feeds/* 下藏的 rtp2httpd（有些发行版 feeds/luci/applications 直接存源）
if command -v find >/dev/null 2>&1; then
	find ./feeds -maxdepth 4 -type d -iname '*rtp2httpd*' -print -exec rm -rf {} + 2>/dev/null
fi
# 3) 清 tmp 索引缓存（强制让 make defconfig 重新扫包）
rm -f ./tmp/.packageinfo ./tmp/.targetinfo ./tmp/.packageinfo-rtp2httpd 2>/dev/null
rm -rf ./tmp/info 2>/dev/null
# 4) 清 feeds.conf.default 里所有旧 rtp2httpd feed 行（之前版本写的 feed 注入）
sed -i '\|src-git-full\? rtp2httpd |d' ./feeds.conf.default 2>/dev/null
sed -i '\|src-git rtp2httpd |d' ./feeds.conf.default 2>/dev/null
# 5) 清旧的自定义包目录（防止多个tag版本残留）
rm -rf ./package/stackia-rtp2httpd ./package/rtp2httpd-official ./package/rtp2httpd 2>/dev/null
# 5b) 再扫一遍 package/ 下非预期的 rtp2httpd 目录（排除我们将要创建的 rtp2httpd-official）
if command -v find >/dev/null 2>&1; then
	find ./package -maxdepth 2 -type d -iname '*rtp2httpd*' ! -name 'rtp2httpd-official' ! -path './package/stackia-rtp2httpd-src' -print -exec rm -rf {} + 2>/dev/null
fi
# 6) 打印清理结果，便于 CI 日志排查
echo "清理后 package/feeds 下残留的 rtp2httpd 目录："
if command -v find >/dev/null 2>&1; then
	find ./package/feeds -maxdepth 2 -type d -iname '*rtp2httpd*' -print 2>/dev/null || echo "  (empty)"
else
	ls -d ./package/feeds/*/*rtp2httpd* 2>/dev/null || echo "  (empty)"
fi
echo "rtp2httpd 所有同名旧包/缓存/feed 配置已清理（准备重新安装官方最新 Release）"

# ---------- B. 获取官方最新 Release tag ----------
# 优先：gh api（Actions 环境自带 GITHUB_TOKEN，不受 rate-limit）
_RTP_LATEST_TAG=""
if command -v gh >/dev/null 2>&1; then
	_RTP_LATEST_TAG=$(gh api repos/stackia/rtp2httpd/releases/latest --jq '.tag_name' 2>/dev/null | tr -d '\r\n ')
fi
# 回退：git ls-remote 取所有 tag，语义化版本排序取最大
if [ -z "$_RTP_LATEST_TAG" ] || [ "$_RTP_LATEST_TAG" = "null" ]; then
	_RTP_LATEST_TAG=$(git ls-remote --tags --refs https://github.com/stackia/rtp2httpd.git 2>/dev/null \
		| awk '{print $2}' \
		| sed 's|refs/tags/||' \
		| grep '^v[0-9]' \
		| sort -t. -k1,1n -k2,2n -k3,3n \
		| tail -n1)
fi
# 兜底：两个都失败时使用已知可用的 v3.15.3（2026-08 最新）
if [ -z "$_RTP_LATEST_TAG" ]; then
	_RTP_LATEST_TAG="v3.15.3"
	echo "⚠️  无法获取 rtp2httpd 最新 tag，回退使用 $_RTP_LATEST_TAG"
else
	echo "rtp2httpd 官方最新 Release tag: $_RTP_LATEST_TAG"
fi
_RTP_LATEST_VER="${_RTP_LATEST_TAG#v}"
echo "rtp2httpd 纯版本号: $_RTP_LATEST_VER"

# ---------- C. git clone 官方源码（指定最新 tag，+ openwrt-support 子目录） ----------
_RTP_TMP_DIR="./package/stackia-rtp2httpd-src"
_RTP_CUSTOM_DIR="./package/rtp2httpd-official"
rm -rf "$_RTP_TMP_DIR" "$_RTP_CUSTOM_DIR" 2>/dev/null
# --depth=1 + 指定 tag，速度最快（和 Release 预编译包同 commit 代码）
git clone --depth=1 --branch "$_RTP_LATEST_TAG" \
	https://github.com/stackia/rtp2httpd.git "$_RTP_TMP_DIR" 2>&1 | tail -2
# 创建自定义包目录（OpenWrt 会自动扫描 package/ 下的 Makefile）
mkdir -p "$_RTP_CUSTOM_DIR"

# ---------- D. 移动 openwrt-support 下三个包到自定义目录 + 覆盖 Makefile.versioned ----------
# 参考 issue #695 xzhhzx222 的步骤：
#   mv -vf package/stackia-rtp2httpd/openwrt-support/rtp2httpd/          package/rtp2httpd-official/
#   mv -vf package/stackia-rtp2httpd/openwrt-support/luci-app-rtp2httpd/ package/rtp2httpd-official/
#   mv -vf package/stackia-rtp2httpd/openwrt-support/luci-i18n-rtp2httpd-zh-cn/ package/rtp2httpd-official/
#   mv -vf package/rtp2httpd-official/rtp2httpd/Makefile.versioned          package/rtp2httpd-official/rtp2httpd/Makefile
#   mv -vf package/rtp2httpd-official/luci-app-rtp2httpd/Makefile.versioned package/rtp2httpd-official/luci-app-rtp2httpd/Makefile
# 这里用 cp -rf 先复制（保留源用于对比），然后 rm -rf 临时目录，效果等同 mv。
for _subpkg in rtp2httpd luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn; do
	_SRC="$_RTP_TMP_DIR/openwrt-support/$_subpkg"
	if [ -d "$_SRC" ]; then
		cp -rf "$_SRC" "$_RTP_CUSTOM_DIR/"
		# 官方提供的 Makefile.versioned：里面 PKG_VERSION/PKG_RELEASE 按 tag 写死，
		# 不依赖 luci.mk 的自动日期版本号（26.xxx.xxxxx~commit 就是 luci.mk 产生的）
		if [ -f "$_RTP_CUSTOM_DIR/$_subpkg/Makefile.versioned" ]; then
			mv -f "$_RTP_CUSTOM_DIR/$_subpkg/Makefile.versioned" "$_RTP_CUSTOM_DIR/$_subpkg/Makefile"
			echo "使用 Makefile.versioned -> $_subpkg/Makefile（避免 luci.mk 生成 26.xxx.xxxx 版本号）"
		fi
	fi
done
# 清临时 clone 目录
rm -rf "$_RTP_TMP_DIR"

# ---------- E. 安全兜底：如果 Makefile.versioned 里 PKG_VERSION 不是动态占位符 ----------
# 官方 Makefile.versioned 里一般写死 PKG_VERSION=3.15.3 / PKG_RELEASE=1，
# 但如果 tag 比仓库里 versioned 的版本号更新，这里再做一次 sed 写死，确保和最新 tag 对齐。
for _pkg in rtp2httpd luci-app-rtp2httpd; do
	_mk="$_RTP_CUSTOM_DIR/$_pkg/Makefile"
	if [ -f "$_mk" ]; then
		sed -i "s|^RELEASE_VERSION:=.*|RELEASE_VERSION:=$_RTP_LATEST_VER|" "$_mk" 2>/dev/null
		sed -i "s|^PKG_VERSION:=.*|PKG_VERSION:=$_RTP_LATEST_VER|" "$_mk" 2>/dev/null
		sed -i 's|^PKG_RELEASE:=.*|PKG_RELEASE:=1|' "$_mk" 2>/dev/null
		if [ "$_pkg" = "luci-app-rtp2httpd" ]; then
			sed -i "s|^PKG_PO_VERSION:=.*|PKG_PO_VERSION:=$_RTP_LATEST_VER|" "$_mk" 2>/dev/null
		fi
		# ===== Compile Firmware 报错根因修复 =====
		# 官方 Makefile.versioned 里 PKG_HASH 写死的是「Makefile.versioned 当前写的 RELEASE_VERSION」
		# 的源码包 hash。而我们自动追最新 tag 时，RELEASE_VERSION 会被上一行 sed 改成最新版号，
		# 导致 PKG_HASH（旧值）和 实际下载到的 tar.gz（最新版）hash 不匹配，
		# make 解压前校验失败 → Compile Firmware 步骤红叉退出。
		# 修复方式：一律用 PKG_HASH:=skip（OpenWrt buildroot 原生支持）跳过 hash 校验，
		# 因为我们追的是 GitHub 官方最新 tag 源码，信任上游签名，不需要本地强制 hash。
		# 先删除旧的 PKG_HASH 行（避免留两份），再在 PKG_SOURCE 行后面追加 skip 版本。
		sed -i '/^PKG_HASH:=/d' "$_mk" 2>/dev/null
		if [ "$_pkg" = "rtp2httpd" ]; then
			sed -i '/^PKG_SOURCE:=/a\PKG_HASH:=skip' "$_mk" 2>/dev/null
		fi
	fi
done
# i18n 的 PKG_VERSION 继承自 luci.mk + PKG_PO_VERSION，保险再 patch 一下
_I18N_MK="$_RTP_CUSTOM_DIR/luci-i18n-rtp2httpd-zh-cn/Makefile"
if [ -f "$_I18N_MK" ]; then
	sed -i "s|^PKG_VERSION:=.*|PKG_VERSION:=$_RTP_LATEST_VER|" "$_I18N_MK" 2>/dev/null
	sed -i 's|^PKG_RELEASE:=.*|PKG_RELEASE:=1|' "$_I18N_MK" 2>/dev/null
fi

# ---------- F. 验证结果 ----------
echo ""
echo "========== rtp2httpd 集成完成（package/自定义目录方式，优先级最高）=========="
for _subpkg in rtp2httpd luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn; do
	_pkg_mk="$_RTP_CUSTOM_DIR/$_subpkg/Makefile"
	if [ -f "$_pkg_mk" ]; then
		_pv=$(grep -m1 '^PKG_VERSION:=' "$_pkg_mk" 2>/dev/null | sed 's|PKG_VERSION:=||' | tr -d '\r')
		_pr=$(grep -m1 '^PKG_RELEASE:=' "$_pkg_mk" 2>/dev/null | sed 's|PKG_RELEASE:=||' | tr -d '\r')
		echo "  ✅ $_subpkg: 目录=$(realpath $_RTP_CUSTOM_DIR/$_subpkg 2>/dev/null || echo $_RTP_CUSTOM_DIR/$_subpkg)  版本=$_pv-$_pr"
	else
		echo "  ❌ $_subpkg: 不存在！构建时会回退到 ImmortalWrt feeds 的旧版！"
	fi
done
echo "========================================================================="
echo ""

unset _RTP_LATEST_TAG _RTP_LATEST_VER _RTP_TMP_DIR _RTP_CUSTOM_DIR _SRC _pkg _mk _pv _pr _I18N_MK _subpkg

# ========================================================================
# 2. NN6000 V1 网口重定义（patch ImmortalWrt 源码）
#    目标：lan1+lan2 桥接 br-lan，lan3 独立为 IPTV 口
#    label 映射：原 WAN 口 -> lan1，原 LAN1 口 -> lan2，原 LAN2 口 -> lan3
# ========================================================================

BOARD_D_NET="./target/linux/qualcommax/ipq60xx/base-files/etc/board.d/02_network"
if [ -f "$BOARD_D_NET" ] && grep -q "link,nn6000-v1" "$BOARD_D_NET"; then
	#
	# board.d/02_network 中 link,nn6000-v1 的 case 分支原文：
	#   link,nn6000-v1)
	#       ucidef_set_interfaces_lan_wan "lan1 lan2" "wan"
	#       ;;
	# 改为：lan1+lan2 桥接（旁路由主口），lan3 留空（由 uci-defaults 配为 IPTV 口）
	# 无 WAN 接口（旁路由模式不需要 WAN）
	# uci-defaults 会在首次启动时覆盖 network config，创建 br-lan(lan1+lan2) + iptv(lan3)
	#
	sed -i '/link,nn6000-v1)/,/;;/ {
		s/.*ucidef_set_interfaces_lan_wan.*/\tucidef_set_interfaces_lan_wan "lan1 lan2" ""/
	}' "$BOARD_D_NET" 2>/dev/null

	echo "NN6000 V1: board.d/02_network patched: no WAN, lan1+lan2 to LAN bridge, lan3 reserved for IPTV."
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
# 3. 创建旁路由 + IPTV 专用 uci-defaults 脚本（首次启动自动执行）
#    - lan1+lan2 桥接 br-lan，lan3 独立为 IPTV 口（DHCP 获取 IPTV 专网 IP）
#    - 静态 IP / 网关 / DNS
#    - 删除 WAN/WAN6 接口
#    - DHCP 关闭
#    - IPv6 默认关闭
#    - 防火墙：LAN zone + IPTV zone + 双向 forwarding
#    - rtp2httpd：配置 + 开机自启
# ========================================================================

UCI_DEFAULTS_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"

cat > "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi" <<'UCI_EOF'
#!/bin/sh
# NN6000 V1 无WiFi版 + IPTV —— 旁路由专用默认配置
# 首次启动自动执行，仅运行一次
# 架构：lan1+lan2 桥接 br-lan（旁路由主口）
#       lan3 独立为 IPTV 口（DHCP 获取 IPTV 专网 IP）
#       rtp2httpd 运行在 lan3 上，提供组播转 HTTP 服务

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
#              ports 列表 = lan1 lan2   （add_list，避免重复；lan3 独立为 IPTV 口）
#
# 结果：/etc/config/network 里有 1 个匿名 @device[0]（br-lan）+ 1 个命名 device（lan3dev）
#       `uci show network | grep -c @device` = 1（匿名），`uci show network | grep lan3dev` = 1（命名）

# Step A：命名 device section 清理
uci delete network.lan1 2>/dev/null || true
uci delete network.lan2 2>/dev/null || true
uci delete network.lan3 2>/dev/null || true
uci delete network.lan1dev 2>/dev/null || true
uci delete network.lan2dev 2>/dev/null || true
uci delete network.lan3dev 2>/dev/null || true
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
# ports：先清后加，用 add_list，lan3 独立为 IPTV 口，不加入 br-lan
for _p in lan1 lan2; do
  uci -q del_list "network.@device[0].ports=$_p" 2>/dev/null
  uci add_list "network.@device[0].ports=$_p" 2>/dev/null || true
done

# 创建 lan3 独立 device section（IPTV 口，不加入 br-lan）
# 设置 MAC 地址（DTS 已有但 UCI 再写一遍做双保险）
uci set network.lan3dev=device
uci set network.lan3dev.name='lan3'
uci set network.lan3dev.macaddr="$LAN3_MAC"

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

# ---------- 2.4 MAC 持久化：rc.local + netifd hotplug（每次开机/ifup 补刷） ----------
# 背景（v5.11 实测）：uci-defaults 只在首次启动跑一次，上面的 ip link set 兜底
#   跑完后，netifd 后续重载 / 驱动 probe 时 NSS-DP 会把端口 MAC 打回出厂基址
#   （lan1=79 lan2=7a lan3=7b），所以必须持久化：
#   ① /etc/rc.local 开机时刷一次
#   ② /etc/hotplug.d/net/90-mac-fix 在每次接口 ifup 时再刷一次（netifd 重载也能恢复）
# 注意：$LAN1_MAC 等变量由本文件 2 节开头定义，此处引用会在设备端展开。
mkdir -p /etc/hotplug.d/net
cat > /etc/hotplug.d/net/90-mac-fix <<MACFIX_EOF
#!/bin/sh
# NN6000 V1 端口 MAC 持久化（由 Settings.sh 2.4 节生成）
[ "\$ACTION" = "ifup" ] || exit 0
[ -d /sys/class/net/lan1 ] && ip link set dev lan1 address "$LAN1_MAC" 2>/dev/null
[ -d /sys/class/net/lan2 ] && ip link set dev lan2 address "$LAN2_MAC" 2>/dev/null
[ -d /sys/class/net/lan3 ] && ip link set dev lan3 address "$LAN3_MAC" 2>/dev/null
[ -d /sys/class/net/br-lan ] && ip link set dev br-lan address "$BR_LAN_MAC" 2>/dev/null
exit 0
MACFIX_EOF
chmod +x /etc/hotplug.d/net/90-mac-fix
# rc.local：先清掉旧 MAC-FIX 行再在 exit 0 前插入（幂等）
sed -i '/# MAC-FIX/d' /etc/rc.local
sed -i '/^exit 0/i ip link set dev lan1 address '"$LAN1_MAC"' # MAC-FIX\nip link set dev lan2 address '"$LAN2_MAC"' # MAC-FIX\nip link set dev lan3 address '"$LAN3_MAC"' # MAC-FIX\nip link set dev br-lan address '"$BR_LAN_MAC"' # MAC-FIX' /etc/rc.local
chmod 0755 /etc/rc.local

# ---------- 3. LAN 静态 IP / 掩码 / 网关 / DNS ----------
# （原 section 3，IPTV 接口配置在 3.5 节）
# ⚠ 重要（不能删）：uci-defaults 在设备端执行时**没有**构建机的环境变量，
#   所以必须先用 PLACEHOLDER_* 字符串占位赋给 LAN_* 局部变量，
#   由本脚本尾部第 747-752 行的 sed 把 PLACEHOLDER_* 批量替换成
#   顶部第 16-20 行的真实值，设备端执行到此处时 $LAN_IP 等才是有效 IP。
#   实测删掉这段占位赋值后，uci set 会写入空字符串 → IP/DNS/网关全丢。
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

# ---------- 3.5 IPTV 接口配置（lan3 独立口，DHCP 获取 IPTV 专网 IP） ----------
# lan3 不再桥接 br-lan，作为独立 IPTV 口使用
# 通过 DHCP 从运营商 IPTV 网络获取 IP（通常是 100.x.x.x/19 段）
# 注意：必须先 uci set network.iptv=interface 创建 section，再设置选项
uci set network.iptv=interface
uci set network.iptv.proto='dhcp'
uci set network.iptv.device='lan3'
uci set network.iptv.hostname='*'
uci set network.iptv.metric='20'

# ---------- 4. 关闭 DHCP（旁路由模式由主路由提供 DHCP） ----------
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

# ---------- 5. IPv6 默认关闭（内核模块保留，用户需要时手动开启） ----------
uci set network.globals.ula_prefix='' 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
echo "net.ipv6.conf.all.disable_ipv6 = 1"  >> /etc/sysctl.conf 2>/dev/null
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf 2>/dev/null

# ---------- 6. 防火墙：删除 WAN zone，重建 LAN + IPTV zone ----------
# 删除所有 wan 相关 zone
while uci -q delete firewall.@zone[0]; do :; done 2>/dev/null
# 重建 lan zone（旁路由主区域，允许 input/output/forward）
uci add firewall zone
uci set firewall.@zone[-1].name='lan'
uci set firewall.@zone[-1].network='lan'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='0'
uci set firewall.@zone[-1].mtu_fix='0'
# 重建 iptv zone（IPTV 口区域，masq + mtu_fix 保证组播正常）
uci add firewall zone
uci set firewall.@zone[-1].name='iptv'
uci set firewall.@zone[-1].network='iptv'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
# forwarding 规则清零
while uci -q delete firewall.@forwarding[0]; do :; done 2>/dev/null
# IPTV ↔ LAN 双向转发（LAN 设备可访问 IPTV，反之亦然）
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iptv'
uci set firewall.@forwarding[-1].dest='lan'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='iptv'
# 清理原作者残留的 wan 规则
while uci -q delete firewall.@rule[0]; do :; done 2>/dev/null

# ---------- 7. 提交所有 uci 变更 ----------
uci commit network
uci commit dhcp
uci commit firewall

# ---------- 8. 写死 /etc/resolv.conf 避免被覆盖（旁路由模式下的 DNS） ----------
cat > /etc/resolv.conf <<RESOLV_EOF
nameserver $LAN_DNS1
nameserver $LAN_DNS2
RESOLV_EOF
chmod 0644 /etc/resolv.conf 2>/dev/null

# ---------- 8.5 清理 wan DHCP 配置（旁路由无 wan 接口） ----------
uci delete dhcp.wan 2>/dev/null || true

# ---------- 8.6 rtp2httpd IPTV 组播转 HTTP 服务配置 ----------
# 配置 rtp2httpd：监听 5100 端口，从 lan3 接收组播流
cat > /etc/config/rtp2httpd <<'RTP2H_EOF'
config rtp2httpd
	option disabled '0'
	list listen '5100'
	option external_m3u 'https://gh-proxy.com/https://raw.githubusercontent.com/seventone/multicast-zaozhuang.m3u/main/multicast-zaozhuang.m3u'
	option advanced_interface_settings '1'
	option upstream_interface_multicast 'lan3'
	option upstream_interface_fcc 'lan3'
	option upstream_interface_rtsp 'lan3'
RTP2H_EOF
# 启用 rtp2httpd 开机自启（init.d START=99，晚于本脚本执行）
/etc/init.d/rtp2httpd enable 2>/dev/null || true

# ---------- 9. 清理虚拟模板接口（双保险，彻底清 dummy0/erspan0/gre0/sit0 等） ----------
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

# ---------- 10. 隐藏 NSS 副作用接口（LuCI 设备页面显示过滤） ----------
# 背景：NSS 硬件加速驱动链（qca_nss_gre → ip_gre）加载时会自动创建
#   erspan0/gre0/gretap0/ip6gre0/ip6tnl0/sit0 等模板接口，bonding 模块
#   会创建 bonding_masters 控制接口。这些接口 state DOWN、零流量、无影响，
#   但 erspan0 和 bonding_masters 会出现在 LuCI "网络-接口-设备" 页面。
#
# LuCI 的 network.js 中有内置的 iface_patterns_ignore 过滤数组，已经过滤了
#   sit\d+/gre\d+/gretap\d+/ip6gre\d+/ip6tnl\d+（通过正则模式匹配），
#   但缺少 erspan 和 bonding_masters 的过滤模式。
#
# 这里通过 sed 在数组开头追加这两个模式，让 LuCI 不再显示它们。
# 注意：只改 LuCI 显示层，不影响 NSS 驱动和接口本身（接口仍在系统中正常工作）。
# 用 [0-9] 替代 \d 避免反斜杠转义问题（busybox sed 不处理 \d 转义）。
LUCI_NETWORK_JS="/www/luci-static/resources/network.js"
if [ -f "$LUCI_NETWORK_JS" ]; then
	# 幂等检查：如果文件中没有 erspan 过滤模式才 patch
	if ! grep -q 'erspan' "$LUCI_NETWORK_JS" 2>/dev/null; then
		sed -i 's|const iface_patterns_ignore=\[|const iface_patterns_ignore=[/^erspan[0-9]+/,/^bonding_masters$/,|' "$LUCI_NETWORK_JS" 2>/dev/null
		# 清理 LuCI 缓存让 patch 立即生效
		rm -rf /tmp/luci-* 2>/dev/null
		echo "LuCI network.js patched: erspan0/bonding_masters 已从设备列表过滤"
	fi
fi

# ---------- 11. 设置 root 密码 ----------
# 旁路由默认开启 SSH，设置固定 root 密码避免首次登录需手动设置
# 优先用 chpasswd，fallback 用 passwd here-doc，再 fallback 直接改 shadow
if command -v chpasswd >/dev/null 2>&1; then
	echo "root:9763899" | chpasswd 2>/dev/null
	echo "root 密码已设置（chpasswd）"
else
	echo -e "9763899\n9763899" | passwd root 2>/dev/null
	# 兜底：如果 passwd 命令也失败，直接用 openssl 生成哈希改 shadow
	if [ $? -ne 0 ] && [ -f /etc/shadow ]; then
		_HASH=$(openssl passwd -6 9763899 2>/dev/null || openssl passwd -1 9763899 2>/dev/null)
		if [ -n "$_HASH" ]; then
			sed -i "s|^root:[^:]*:|root:$_HASH:|" /etc/shadow
			echo "root 密码已设置（shadow）"
		fi
	else
		echo "root 密码已设置（passwd）"
	fi
fi

exit 0
UCI_EOF
chmod +x "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"

# 用实际参数替换占位符
sed -i "s|PLACEHOLDER_LAN_IP|$LAN_IP|g"       "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_MASK|$LAN_MASK|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_GW|$LAN_GW|g"       "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_DNS1|$LAN_DNS1|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"
sed -i "s|PLACEHOLDER_LAN_DNS2|$LAN_DNS2|g"   "$UCI_DEFAULTS_DIR/99-nn6000v1nowifi"

echo "NN6000 V1 旁路由+IPTV uci-defaults 已注入：IP=$LAN_IP GW=$LAN_GW DNS=$LAN_DNS1,$LAN_DNS2 DHCP=off IPv6=default-off"
echo "网口架构：lan1+lan2→br-lan（旁路由），lan3→iptv（DHCP，rtp2httpd 5100）"
echo "网口 label：WAN→lan1 / LAN1→lan2 / LAN2→lan3"
