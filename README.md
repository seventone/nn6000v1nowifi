# NN6000 V1 无WiFi版 固件编译 (OpenWRT / ImmortalWrt)

基于 [VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI) 精简而来，仅用于编译 **NN6000 V1 无WiFi版**（link_nn6000-v1，IPQ6018 平台）的固件。

# 源码来源

ImmortalWrt 官方版：
https://github.com/immortalwrt/immortalwrt.git

VIKINGYFY 自用版（默认使用）：
https://github.com/VIKINGYFY/immortalwrt.git

# 固件简要说明

- 目标设备：**NN6000 V1 无WiFi版**（qualcommax / ipq60xx / link_nn6000-v1）
- WiFi 驱动：已全部禁用（无WiFi版）
- 自动编译：每天早上 5 点（Auto-Clean 运行完成后触发）
- 手动编译：可在 GitHub Actions 的 `NN6000-V1-WIFI-NO` 工作流中点击 Run workflow
- 固件信息里的时间为编译开始的时间，方便核对上游源码提交时间

# 目录简要说明

- `.github/workflows/` — 自定义 CI 配置
  - `NN6000V1NOWIFI.YML` — NN6000 V1 无WiFi版编译入口
  - `WRT-CORE.yml` — 云编译公用核心
  - `Auto-Clean.yml` — 自动清理旧 Release / Workflow
  - `Cache-Clean.yml` — 自动清理缓存
- `Scripts/` — 自定义脚本
  - `Settings.sh` — 旁路由默认配置（静态IP/DHCP/网口/防火墙/默认主题等）
- `Config/` — 自定义配置
  - `GENERAL.txt` — 通用内核配置（仅保留基础网络/存储/系统，插件后期 opkg 安装）
  - `IPQ60XX-WIFI-NO.txt` — NN6000 V1 无WiFi版专属配置（仅保留 link_nn6000-v1 设备）

