# 让 Intel iwlwifi（8260 等）在 5GHz 上运行 STA+AP（repeater）的修复说明

## 1. 背景与现象

在一块 **Intel Wireless-AC 8260**（PCI `24f3/9010`，固件 `8000C-36.ucode`，OpenWrt/backports 7.2，内核 6.18）上尝试把它当作 **5GHz 无线中继**（先以 STA 连上一个上联 AP，再在同一信道开一个 AP 供其它客户端接入）时，AP 始终起不来：

```
hostapd: Frequency 5180 (primary) not allowed for AP mode, flags: ... NO-IR
hostapd: Could not select hw_mode and channel. (-3)
```

常见说法是“Intel 卡 5GHz 必须先连上 station 才能开 AP”，但在 OpenWrt 里即使 STA 已正常关联，AP 依然失败。

## 2. 结论

这张卡**并非硬件上不能做 5GHz AP**，而是三处软件把路挡住了：

1. hostapd 会**预先**把带 `NO_IR`/`IR_CONCURRENT` 标记的信道从候选里禁用掉，根本不尝试；
2. 内核 cfg80211 的 **NO_IR relaxation（`CFG80211_REG_RELAX_NO_IR`）默认没有编译进 backports**，且其放行名单只包含 `P2P_GO`，**不含普通 `AP`**；
3. 上述 relax 机制本来就是为了“**IR_CONCURRENT 信道上、当本 phy 存在一个已关联的同信道/同 UNII STA 时允许起 AP**”而设计——iwlwifi 一直通过 `REGULATORY_ENABLE_RELAX_NO_IR` 声明支持它，只是前两层挡死了。

打通之后，这张 8260 可以稳定运行 **STA(5G 上联) + AP(5G) 同信道中继**：`AP-ENABLED`、客户端可接入并正常转发流量。

## 3. 根因细节（为什么“先连 STA 也没用”）

- 该卡是 **self-managed regulatory（LAR）** 设备：`iw reg get` 里 `phy#0 (self-managed) country 00`。它**无视用户/系统的 `iw reg set` / `option country`**（实测设了 `country CN/RU` 后 phy 仍是 `00`）。
- 固件只有在通过 **802.11d（beacon 里的 Country IE）自己“探测”到国家**后才会离开 world（`00`）域；实测**关联到会广播 Country IE 的 RU AP（MikroTik）后 phy 仍是 `00`**，因为 iwlwifi 驱动会丢弃“已关联状态下”来自 WIFI 源的法规域更新（`nvm.c` 中 `MCC_SOURCE_WIFI` 且 `iwl_mvm_is_vif_assoc` 时忽略）。
- 因此这张卡在当前固件/内核下，**“等固件学到正确国家码”这条路走不通**，必须借助内核的 NO_IR relaxation。

## 4. 改动清单（共 3 处）

| # | 文件 | 作用 |
|---|---|---|
| 1 | `package/network/services/hostapd/patches/305-AP-do-not-disable-NO_IR-channels.patch` | hostapd 不再因 `NO_IR` 预禁用信道；是否允许起 AP 交给内核 cfg80211 判定 |
| 2 | `package/kernel/mac80211/patches/subsys/990-cfg80211-allow-AP-in-NO_IR-relaxation.patch` | cfg80211 NO_IR relaxation 放行名单加入 `NL80211_IFTYPE_AP` |
| 3 | `package/kernel/mac80211/Makefile` | 使能 `CFG80211_REG_RELAX_NO_IR`（backports 默认不编入） |

> 说明：这三处对设置了正确国家码（CN/RU/…）的正常配置**无任何行为差异**（那些信道本来就没有 NO_IR 标记）；只在 “world/00 + NO_IR/IR_CONCURRENT 信道”场景下放行“尝试”，最终仍由内核把关，不会绕过合规限制。

## 5. 补丁完整内容

### 5.1 hostapd：不预禁用 NO_IR 信道

`package/network/services/hostapd/patches/305-AP-do-not-disable-NO_IR-channels.patch`

```diff
--- a/src/ap/hw_features.c
+++ b/src/ap/hw_features.c
@@ -178,6 +178,10 @@
 			 * to initiate radiation (a.k.a. passive scan and no
 			 * IBSS).
 			 * Use radar channels only if the driver supports DFS.
+			 * NB (OpenWrt): channels that are only NO_IR/IR_CONCURRENT
+			 * are kept usable here; whether an AP may actually start
+			 * is still validated by cfg80211 (NO_IR relaxation with a
+			 * concurrent station).
 			 */
 			if ((feature->channels[j].flag &
 			     HOSTAPD_CHAN_RADAR) && dfs_enabled) {
@@ -186,9 +190,7 @@
 				     HOSTAPD_CHAN_RADAR) &&
 				    !(iface->drv_flags &
 				      WPA_DRIVER_FLAGS_DFS_OFFLOAD) &&
-				    !iface->assisted_dfs) ||
-				   (feature->channels[j].flag &
-				    HOSTAPD_CHAN_NO_IR)) {
+				    !iface->assisted_dfs)) {
 				feature->channels[j].flag |=
 					HOSTAPD_CHAN_DISABLED;
 			}
```

**行为**：`RADAR`（且无 DFS 能力）信道仍被禁用（保持不变）；只有“纯 `NO_IR`/`IR_CONCURRENT`”信道不再被 hostapd 提前禁用，是否可用交给内核判定。

### 5.2 cfg80211：NO_IR relaxation 允许普通 AP

`package/kernel/mac80211/patches/subsys/990-cfg80211-allow-AP-in-NO_IR-relaxation.patch`

```diff
--- a/net/wireless/chan.c
+++ b/net/wireless/chan.c
@@ -1705,8 +1705,13 @@
 	    !(wiphy->regulatory_flags & REGULATORY_ENABLE_RELAX_NO_IR))
 		return false;
 
-	/* only valid for GO and TDLS off-channel (station/p2p-CL) */
+	/* GO, regular AP and TDLS off-channel (station/p2p-CL) may use an
+	 * IR_CONCURRENT channel when another interface on this wiphy is
+	 * associated on the same channel/UNII band. Regular AP is required for
+	 * client+AP (repeater) operation on self-managed-regulatory cards.
+	 */
 	if (iftype != NL80211_IFTYPE_P2P_GO &&
+	    iftype != NL80211_IFTYPE_AP &&
 	    iftype != NL80211_IFTYPE_STATION &&
 	    iftype != NL80211_IFTYPE_P2P_CLIENT)
 		return false;
```

### 5.3 backports 构建：打开 NO_IR relaxation

`package/kernel/mac80211/Makefile`，`config-y` 列表中加入：

```make
config-y:= \
 	WLAN \
 	CFG80211_CERTIFICATION_ONUS \
+	CFG80211_REG_RELAX_NO_IR \
 	MAC80211_RC_MINSTREL \
```

> `CFG80211_REG_RELAX_NO_IR` 在 backports 中默认关闭且依赖 `CFG80211_CERTIFICATION_ONUS`（后者 OpenWrt 已默认开启）。不开这个符号，5.2 的 relax 路径会被整体编译掉，两个补丁都无效。

## 6. 部署 / 构建

对 `10.32.15.130` 这类 x86_64 目标：

```bash
cd <openwrt-root>
make -j$(nproc)          # 重新构建（hostapd + mac80211/cfg80211 等内核模块 + 镜像）
# 刷入目标设备后重启
```

## 7. 使用配置示例（/etc/config/wireless）

必须**先让 STA 关联到上联 AP，且 AP 与 STA 同信道**（8260 单射频，接口组合限制 `#channels <= 1`，只能同信道；信道须为非 DFS 的 5GHz，如 36–48 或 149–165）：

```sh
config wifi-device 'radio0'
	option type 'mac80211'
	option band '5g'
	option channel '40'          # 与上联 AP 相同的信道
	option htmode 'VHT80'
	# 可选：不给 country，或给一个当前 phy 实际生效不了的国家码均可

config wifi-iface 'uplink'
	option device 'radio0'
	option mode 'sta'
	option ssid '上联SSID'
	option encryption 'sae'      # 视上联而定
	option key '....'
	option network 'wan'         # 本机作为路由器使用时，STA 作 WAN

config wifi-iface 'lanap'
	option device 'radio0'
	option mode 'ap'
	option ssid '本机AP'
	option encryption 'psk2'
	option key '....'
	option network 'lan'
```

验证（目标设备上）：

```
iw dev phy0-sta0 link                 # STA 已关联
logread | grep hostapd                # 应看到 phy0-ap0: AP-ENABLED
iw dev phy0-ap0 station dump          # 客户端已关联
```

## 8. 限制与后续

- **必须是 STA+AP 并发（repeater）**：relax 要求 phy 上存在一个已关联的 STA，且 AP 与它在同一信道/同一 UNII。
- **纯 AP（无 STA 上联）**不在本方案覆盖范围：此时 phy 仍停在 world `00`，NO_IR 无法 relax，5GHz AP 仍起不来。要支持纯 AP，需另行修改 iwlwifi（例如初始化时向固件请求国家码 / 提供非 self-managed 路径），属另一项工作。
- **`channel 'auto'`（ACS）的边角**：在未设国家码的 world 域下，ACS 可能把 NO_IR 信道也纳入候选而后被内核拒绝，导致重试/起不来。规避：不要用 auto，或显式设置 country。
- 由于改动是有意放宽，建议在对外发布/升级前保留注释与这条说明，便于追溯。

## 9. 如何回退

删除/还原上述三处改动即可恢复原行为：

```bash
rm package/network/services/hostapd/patches/305-AP-do-not-disable-NO_IR-channels.patch
rm package/kernel/mac80211/patches/subsys/990-cfg80211-allow-AP-in-NO_IR-relaxation.patch
# 并从 package/kernel/mac80211/Makefile 的 config-y 中删除 CFG80211_REG_RELAX_NO_IR 行
```

重新构建并刷机后即回到“5GHz AP 在 world 域下无法启动”的原状态。

## 10. 参考

- 现象与机制分析：tildearrow, *making hostapd LAR-friendly (on Intel 5GHz wireless cards)*
- Linux kernel bug 206469（LAR 下 `iw reg set` 被无视）
- backports 7.2 相关源码位置：
  - `drivers/net/wireless/intel/iwlwifi/mvm/mac80211.c`（`REGULATORY_ENABLE_RELAX_NO_IR`、self-managed 判定）
  - `drivers/net/wireless/intel/iwlwifi/mvm/nvm.c`（`MCC_SOURCE_WIFI` 且已关联时丢弃法规域更新）
  - `net/wireless/chan.c`（`cfg80211_ir_permissive_chan` / `cfg80211_reg_check_beaconing`）
- 本说明对应验证设备：`10.32.15.130`（OpenWrt x86/64，内核 6.18.44，backports 7.2）
