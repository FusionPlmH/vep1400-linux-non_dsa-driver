[English](README.md) &nbsp;·&nbsp; **简体中文**

# vep1400 —— Dell VEP1400 / VMware SD-WAN Edge 610 标准 Linux 支持

为 **Dell VEP1400**（同款机型：**VMware SD-WAN Edge 610** 非 X 版，Intel Atom
C3308 "Denverton"）提供板级支持，让六个前面板 RJ45 口和两个 SFP 笼在**原版
Debian / Ubuntu / Proxmox VE / VyOS** 上直接可用 —— 不需要自编译内核，不需要
设备树，也不需要 DSA。

真机实测：Debian 13.7 / 内核 6.12，六个端口全部 1000 Mb/s，单口实测约 930 Mb/s。

```
    ┌──────────────────────────── Edge 610 / VEP1400 ───────────────────────────┐
    │                                                                           │
    │  GE1 ─┐                                                                   │
    │  GE2 ─┼─ PHY1..3 ─┐                                                       │
    │  GE3 ─┘           │   Marvell 88E6190                                     │
    │                   ├─── port 10 ── 802.1Q ── 0000:03:00.0 (ixgbe) ── eno1  │
    │  GE4 ─┐           │                                                       │
    │  GE5 ─┼─ PHY4..6 ─┤                                                       │
    │  GE6 ─┘           └─── port  9 ── 802.1Q ── 0000:03:00.1 (ixgbe) ── eno2  │
    │                                                                           │
    │  SFP1 ── 0000:05:00.1 (ixgbe)     SFP2 ── 0000:05:00.0 (ixgbe)            │
    └───────────────────────────────────────────────────────────────────────────┘
```

`vep1400.ko` 接管交换芯片：通过被 Dell 固件隐藏的 Denverton P2SB 焊盘位操作
SMI 总线，把 88E6190 配置成与 Dell DiagOS 相同的"每个前面板口一个 VLAN"模型，
上电六个 PHY，**然后就不再碰它们**。插上网线后由 PHY 自己的自协商在 2–6 秒内
协商到双方最高速率，和普通网卡完全一样。模块同时关闭 PIC 看门狗、打开 SFP
发射。

`vep1400-net.service` 随后在两个上行口之上创建 `GE1`…`GE6`，并把两个 SFP 笼
重命名为 `SFP1`/`SFP2`。

---

## 快速开始

### 1. 一行命令（不用 git，也不用下载）

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
```

系统里没有 `curl` 时，用 `wget` 效果完全一样：

```sh
wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
```

想要最干净的开机流程可以加上 `--initramfs`（见 [安装选项](#安装选项)）：

```sh
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo bash -s -- --initramfs

wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo bash -s -- --initramfs
```

`get.sh` 会下载发布归档、在临时目录解包并执行 `install.sh`。它接受
`install.sh` 的全部选项，并支持以下环境变量（需要镜像、代理或自建下载站时用）：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `VEP1400_BASE` | `https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver` | 仓库基地址 |
| `VEP1400_REF` | `main` | 要下载的分支 |
| `VEP1400_TARBALL` | *（未设置）* | 完整归档地址（`.tar.gz` 或 `.zip`），优先级最高 |

```sh
# 自建镜像，tar.gz 或 zip 都支持
curl -fsSL https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo VEP1400_TARBALL=https://neodev.team/vep1400-linux-non_dsa-driver.zip bash

wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh \
  | sudo VEP1400_TARBALL=https://neodev.team/vep1400-linux-non_dsa-driver.zip bash
```

### 2. 用 git

```sh
sudo apt install -y dkms linux-headers-$(uname -r)
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./install.sh
sudo reboot
```

## 环境要求

| | |
|---|---|
| 硬件 | Dell VEP1400 / VMware SD-WAN Edge 610（非 X） |
| 系统 | Debian 12/13、Ubuntu 22.04/24.04、Proxmox VE 8/9、VyOS 1.4+ |
| 内核 | 5.15 – 6.x，需安装头文件 `linux-headers-$(uname -r)` |
| 工具 | `dkms`（可选但推荐）、`curl` 或 `wget`、`i2c-tools`（仅诊断用） |

Atom C3558 的 **Edge 610X / VEP1400-X** 交换机配置不同，本版本**不支持**。

## 硬件信息

以下全部读自真机（`dmidecode`、`lspci`、`lscpu`），不是抄宣传页。

| | |
|---|---|
| 系统 | Dell EMC `EDGE610`，DMI Family `VEP1400`，SKU `08VT73`，BIOS `3.43.0.9-8` |
| 主板 | `EDGE610-CPU` |
| CPU | Intel Atom C3308（Denverton，14nm），2 核 2 线程，1.6 GHz 基频 / 2.1 GHz 睿频，4 MB L2，`01:00.0` 为 QAT 加速器 |
| 内存 | 4 GB DDR4-2400 ECC UDIMM（实际跑 1866 MT/s），4 个插槽，最大 128 GB |
| 存储 | 16 GB eMMC（`mmcblk0`），另有 SD 卡槽和 1 个 SATA 口 |
| 交换芯片 | Marvell 88E6190 rev 1 —— 6 个前面板 PHY + 2 个用作 CPU 上行的 SerDes 口 |
| 网卡 | 4 个 Intel X553 Backplane `8086:15c3`：`03:00.0/.1` 接交换芯片，`05:00.0/.1` 是 SFP 笼 |
| 前面板 | 6× 10/100/1000BASE-T RJ45，2× SFP |
| 串口 | `ttyS0`，115200 8N1 |
| 散热 | **纯被动散热 —— 无风扇，SMBus 上也没有风扇控制器** |
| 看门狗 | PIC 位于 SMBus `0x22`/`0x24`，未关闭时上电 4–5 分钟强制重启 |

上行口协商结果为 `1000baseKX/Full`，即交换芯片与 X553 之间走 1000BASE-X。
本机 **2.5G 无法协商**（见 [关于 1G 协商](#关于-1g-协商)）。

## 端口映射与 MAC

| Linux | 交换端口 | PHY | 上行口 | VLAN |
|---|---|---|---|---|
| `GE1` | 1 | 1 | `eno1`（03:00.0，port 10） | 1 |
| `GE2` | 2 | 2 | `eno1` | 2 |
| `GE3` | 3 | 3 | `eno1` | 3 |
| `GE4` | 4 | 4 | `eno2`（03:00.1，port 9） | 4 |
| `GE5` | 5 | 5 | `eno2` | 5 |
| `GE6` | 6 | 6 | `eno2` | 6 |
| `SFP1` | — | — | `05:00.1` | 不带标签 |
| `SFP2` | — | — | `05:00.0` | 不带标签 |

`GE1`…`GE6` 的 MAC 取自对应上行口的 MAC 加固定偏移（`+0x0a … +0x0f`），保证
每个接口的地址唯一。

## 为什么不用 DSA？

上游 `mv88e6xxx` DSA 驱动本来是标准做法，但 Debian、Ubuntu、Proxmox VE 和
VyOS 的内核全部是 `# CONFIG_NET_DSA is not set`（可用
`grep NET_DSA /boot/config-$(uname -r)` 确认），而 88E6190 的 SMI 总线并没有
接到任何 MDIO 控制器上，也无法通过 ACPI/DT 描述。对"下载即用"的项目来说，让
每个发行版都重编内核不可接受。因此本驱动采用和厂家固件相同的思路：把交换机
配成一组 VLAN 接入端口，Linux 侧看到的就是六个普通以太网口。

```
GE1..GE3 -> eno1 (03:00.0) -> 交换芯片 port 10，VLAN 1..3
GE4..GE6 -> eno2 (03:00.1) -> 交换芯片 port  9，VLAN 4..6
```

每个前面板口都是安全的 802.1Q access 口，上行口只承载带标签的流量，永远不要
在上面配置地址。

## 安装选项

```sh
sudo ./install.sh              # DKMS 编译安装，enable 并立即启动服务
sudo ./install.sh --no-start   # 安装并 enable，但本次不启动（重启后生效）
sudo ./install.sh --no-dkms    # 只针对当前运行内核编译，不装 DKMS
sudo ./install.sh --initramfs  # 同时把模块放进 initramfs
```

根文件系统挂载很慢（加密根分区、fsck）时建议用 `--initramfs`：PIC 看门狗在
上电 4–5 分钟后会强制重启，需要模块尽早关闭它。它同时让交换机上行速率档位在
`ixgbe` probe 之前写入，因此开机时不需要重新加载网卡（见
[关于 1G 协商](#关于-1g-协商)）。

卸载：

```sh
sudo ./uninstall.sh
```

## 使用这些端口

`vep1400-net.service` 开机创建 `GE1`…`GE6`，像普通网卡一样配置即可，
例如 `/etc/network/interfaces`：

```
auto GE1
iface GE1 inet dhcp
```

或者 NetworkManager：

```sh
nmcli con add type ethernet ifname GE1 con-name GE1 ipv4.method auto
```

> **不要**给 `eno1`/`eno2` 配地址。它们是内部交换机上行口，只承载带标签的
> 流量。
>
> **不要**把两个 `GE*` 桥接在一起。它们在交换芯片内部本来就属于同一广播域
> （仅靠 VLAN 隔离），桥接会造成环路。

两个端口配在同一网段是允许的，但 Linux 同一网段只保留一条路由 —— 驱动为此
在 `GE*` 上默认设置了 `arp_ignore=1` 和 `arp_announce=2`，保证回包从收到请求
的那个口发出。

## 验证

```sh
sudo /usr/lib/vep1400/vep1400-report.sh
```

正常启动的内核日志：

```
vep1400: iSMT bus 0 (SMBus iSMT adapter at dfe3c000)
vep1400: PIC watchdog disarmed
vep1400: P2SB hidden by firmware, BAR 0x00000000fd000000 from iomem
vep1400: Marvell 88E6190 rev 1
vep1400: X553 fn0 NW_MNG_IF_SEL 0x00102002 -> 0x02082002 (1000M)
vep1400: X553 fn1 NW_MNG_IF_SEL 0x00102002 -> 0x02082002 (1000M)
vep1400: GE1 -> VLAN 1 via CPU port 10
...
vep1400: CPU port 10 link up (1G)
vep1400: CPU port 9 link up (1G)
vep1400: front panel PHYs powered up, autonegotiation running
vep1400: switch ready
vep1400: GE3 link up (1G)
vep1400: GE6 link up (1G)
```

`/sys/kernel/debug/vep1400/info` 汇总驱动状态，包括 X553 速率档位是否写入成功：

```
switch_id    0x1901 (88E6190 rev 1)
x553_speed   1000
x553_strap   applied
phy_speed    0
led_init     1
cpu_port_10   up
cpu_port_9    up
```

`/sys/kernel/debug/vep1400/ports` 显示每个交换端口的实时状态（`up`/`down` 是
交换芯片自己的视角）：

```
port status mac_ctl ctl0 pvid ctl2 led link
0    0x0d00 0x0003  0x007c 1    0x2080 0x0000 up
1    0x100f 0x0003  0x007f 1    0x2c80 0x0030 down
...
3    0x5e4f 0x0003  0x007f 3    0x2c80 0x0030 up
6    0x1e0f 0x0003  0x007f 6    0x2c80 0x0030 up
9    0x0e49 0x203e  0x007f 1    0x2c80 0x0022 up
10   0x0e49 0x203e  0x007f 1    0x2c80 0x0022 up
```

某个口表现异常时：

```sh
sudo /usr/lib/vep1400/vep1400-linkdiag.sh 3
```

```
port 3: link up  speed=1G  duplex=full  an=on  an-complete=yes
  local: anar=0x05e1 1000t-ctrl=0x0200 -> [100FD 100HD 10FD 10HD 1000FD]
  peer : anlpar=0x4de1 (10/100), 1000t-status=0x7800 -> [100FD 100HD 10FD 10HD]
```

它会打印本端和对端各自的自协商能力，一眼就能看出是对端只有 10/100，还是网线
质量有问题。

## 模块参数

在 `/etc/modprobe.d/vep1400.conf` 中设置（安装时已生成默认文件）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `watchdog` | `1` | 关闭 PIC 硬件看门狗。不关的话机器每 4–5 分钟重启一次。 |
| `sfp_tx` | `1` | 清除两个 SFP 笼的 `TX_DISABLE`（板载 CPLD 0x31）。 |
| `x553_speed` | `1000` | X553 背板速率档位：`1000`、`2500`，或 `0`（保留 NVM 值）。 |
| `phy_speed` | `0` | `0` = 前面板自协商；`10`/`100`/`1000` 强制速率。 |
| `led_init` | `1` | 初始化前面板 LED 寄存器。 |
| `bus_num` | `-1` | 看门狗/SFP 所用 iSMT 总线号；`-1` 表示按名字自动查找。 |
| `p2sb_bar_addr` | `0` | P2SB MMIO BAR；`0` 表示自动探测（一般都能探测到）。 |

`/etc/modprobe.d/vep1400.conf` 的默认内容：

```
softdep ixgbe pre: vep1400
options vep1400 watchdog=1 sfp_tx=1 x553_speed=1000 phy_speed=0 led_init=1
```

`softdep` 这一行很关键：驱动要写 X553 的 `NW_MNG_IF_SEL` 速率档位，而 `ixgbe`
只在 probe 时读一次该寄存器。先加载 `vep1400` 就能让上行口直接以 1G 起来，
无需卸载任何模块。

多数发行版把 `ixgbe` 放进了 initramfs，模块在里面无法排到它前面 —— 此时
`/sys/kernel/debug/vep1400/info` 会显示 `x553_strap busy`，`vep1400-net.service`
会在开机时重新加载一次 `ixgbe`（此时还没有配置任何地址，不会有影响）。用
`--initramfs` 安装可以避免这次重载：模块已经在 initramfs 里加载，速率档位在
`ixgbe` 绑定之前就写好了。

如果是手动在 `ixgbe` 之后加载模块，需要自行重新加载网卡驱动：

```sh
sudo modprobe -r ixgbe && sudo modprobe ixgbe
```

## 关于 1G 协商

把千兆协商做稳定花了不少逆向工作，这些细节在排障时很有用：

* **板子上的 strap 是错的。** 前面板 PHY 复位后 `1000BASE-T 控制寄存器
  (0x09) = 0x0e00`，同时置了"手动 master"和"手动 slave"，是非法组合，自协商
  永远无法完成。驱动把它改写成 `0x0200`（自动 master/slave）。
* **PHY 默认是下电的。** 复位后 `BMCR = 0x1940`。驱动用
  `BMCR = 0x1140 | AN_RESTART` 上电并启动一次自协商。
* **PHY 只在加载时写一次。** 任何一次 `BMCR` 写入都会重启自协商，所以"帮忙"
  式的插线检测反而会不断打断协商 —— 早期的 fallback/强制速率状态机正是因此
  导致千兆不稳定，现已彻底删除。链路监视只读不写。
* **有些对端要 6–12 秒。** 这是 1000BASE-T 自协商的正常时间，不是驱动问题。
  内核日志会记录状态变化，`vep1400-linkdiag.sh` 能确认对端到底有没有宣告
  1000BASE-T。
* **2.5G 在本机上无法协商。** X553 的 KR PHY 和 88E6190 的 2500BASE-X PCS
  在该模式下都无法完成自协商，请保持 `x553_speed=1000`。

参考机实测：两个前面板口之间打环 899–909 Mbit/s，对 RTL8153 USB 网卡
927–931 Mbit/s，400 MB TCP 传输有效载荷 911 Mbit/s，VLAN 拆分没有可测量的
开销。

## 排障

**没有 `GE1`…`GE6`。**
看 `systemctl status vep1400-net` 与 `journalctl -u vep1400-net`。脚本会按需加载
`ixgbe`，然后需要 `eno1`/`eno2`；如果 `ixgbe` 在速率档位写入之前就已经 probe
（`/sys/kernel/debug/vep1400/info` 里显示 `x553_strap busy`），脚本会自动重载
一次 `ixgbe`。

**`vep1400: unexpected switch id`。**
SMI 读取失步。检查 `dmesg | grep P2SB`：BAR 应接近 `0xfd000000`，
`north reg0` 不能是 `0xffffffff`。特殊固件版本可显式传 `p2sb_bar_addr=`。

**`vep1400: no iSMT SMBus adapter`。**
`i2c_ismt` 没加载。`modprobe i2c_ismt`，或传 `bus_num=<n>`。此时只会跳过看门狗
和 SFP 发射，端口仍然可用 —— 但机器会在 4–5 分钟后重启。

**机器每隔几分钟重启。**
看门狗没关掉：确认 `watchdog=1`，且模块加载足够早（`softdep` 正确、
`vep1400.service` 已 enable）。

**某个口只协商到 100M。**
运行 `vep1400-linkdiag.sh <n>`。若对端也宣告 1000BASE-T，问题在网线或对端口；
本机实测过"劣质网线 + 路由器上实际不是千兆的 LAN 口"两种情况都会落到 100M。

**LED 不亮。**
`led_init=1`（默认）。该参数是只读的，要重新初始化 LED 请重载模块
（`modprobe -r vep1400 && modprobe vep1400`）。

**升级内核后失效。**
这正是 DKMS 的用途；检查 `dkms status` 与 `journalctl -u dkms`。没有用
`--no-dkms` 时模块会自动为新内核重编。

## 目录结构

```
src/vep1400_switch.c   88E6190 初始化、X553 档位、PHY、LED、链路监视、debugfs
src/vep1400_board.c    I²C：PIC 看门狗、SFP TX_DISABLE
src/vep1400_mdio.h     P2SB 焊盘、位操作 SMI、VTU/SERDES/PHY 辅助函数
scripts/               netup、teardown、report、linkdiag
systemd/               vep1400.service、vep1400-net.service
modprobe/vep1400.conf  softdep 与默认参数
initramfs/             可选的提前加载钩子
get.sh                 免 git 下载安装脚本
```

驱动刻意保持精简，加载完成后对硬件只读：每 3 秒读一次 PHY 状态寄存器，几个
debugfs 文件，没有任何会写硬件的定时器。

## 备注

* 本机**无风扇**，纯被动散热，SMBus 上也没有风扇控制器（0x1b 无设备）。CPU
  温度来自 CPU 自带的 `coretemp` 传感器，空闲约 47–50 °C。
* 前面板 PHY、交换芯片和上行口只配置一次。换线、改速率、对端重启都由 PHY 自身
  状态机处理。
* 寄存器序列来自公开资料与对原厂固件行为的观察；本项目不含任何 Dell / VMware
  代码。

## 许可

GPL-2.0 —— 见 [LICENSE](LICENSE)。
