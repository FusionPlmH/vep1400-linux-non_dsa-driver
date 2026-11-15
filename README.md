[English](README.en.md) &nbsp;·&nbsp; **简体中文**

# Dell VEP1400 / VMware Edge 610 —— 标准 Linux 驱动

把 **Dell VEP1400**（= **VMware SD-WAN Edge 610** 非 X 版，Atom C3308）的 6 个
前面板 RJ45 口和 2 个 SFP 笼跑在**原版 Debian / Ubuntu / Proxmox VE / VyOS** 上
—— 不用自编内核，不用设备树，不需要 DSA。

```
   GE1..GE3 ─┐
             ├─ 88E6190 port 10 ─ 802.1Q ─ X553 03:00.0 ─ eno1
   GE4..GE6 ─┤
             └─ 88E6190 port  9 ─ 802.1Q ─ X553 03:00.1 ─ eno2

   SFP1 = X553 05:00.1        SFP2 = X553 05:00.0
```

交换芯片是 Marvell 88E6190。常规做法是走 DSA，让内核把它拆成 `GE1`…`GE6` —— 但
Debian、Ubuntu、PVE、VyOS 的发行版内核都是 `# CONFIG_NET_DSA is not set`（VyOS 连
`CONFIG_NET_SWITCHDEV` 也关了），而它的 SMI 总线既没接到任何 MDIO 控制器，也没法用
ACPI/DT 描述。为一块板让每个发行版重编内核不现实，所以这里走厂家 DiagOS 的老路：
交换机内部配成**一个前面板口一个 802.1Q VLAN**，Linux 侧看到的就是 6 个普通网口。

配置靠驱动通过被 Dell 固件隐藏的 P2SB 焊盘位 bit-bang SMI 完成；6 个 PHY 只在加载时
上电初始化一次，之后完全交给自协商 —— 插线即用，行为和普通网卡一样。同时关闭 PIC
看门狗、打开 SFP 发射。上行口协商为 `1000baseKX/Full`（交换芯片 ↔ X553 走
1000BASE-X），本机 **2.5G 无法协商**。

实测：六个口全部协商到 1000 Mb/s（Debian 13 与 VyOS 1.3.4 双系统验证）。

## 快速开始

先在**能上网的通道**上把管理和外网准备好再动手 —— 装驱动要下内核头和包，而加载驱动
会短暂打断 GE* 口。这块板只有一个管理面、纯被动散热，**无线是最省事的选择**；不要
把某个 GE 口当作安装期间唯一的管理口。

**VyOS**（原生无线配置。`name-server` 这句别漏 —— VyOS 默认不配 DNS，缺了它后面
`ping deb.debian.org` 一定失败，而 `ping 1.1.1.1` 却是通的）：

```
configure
set system name-server 1.1.1.1
set interfaces wireless wlan0 type station
set interfaces wireless wlan0 physical-device phy0
set interfaces wireless wlan0 ssid "<SSID>"
set interfaces wireless wlan0 security wpa mode wpa2
set interfaces wireless wlan0 security wpa passphrase "<PSK>"
set interfaces wireless wlan0 address dhcp
commit
save
```

**Debian / Proxmox VE**（ifupdown + wpasupplicant，PVE 也是用这个文件）：

```sh
apt install -y wpasupplicant
cat >> /etc/network/interfaces <<'EOF'

auto wlp2s0
iface wlp2s0 inet dhcp
	wpa-ssid <SSID>
	wpa-psk  <PSK>
EOF
ifup wlp2s0
```

**Ubuntu Server**（netplan，写 `/etc/netplan/50-wifi.yaml` 后 `sudo netplan apply`）：

```yaml
network:
  version: 2
  wifis:
    wlp2s0:
      access-points:
        "<SSID>":
          password: "<PSK>"
      dhcp4: true
```

（配置里的 `wlp2s0` 换成实际的无线网卡名，`ip -br link` 可查。）

装之前确认真的能上网 —— 下面两条命令 Debian / PVE / VyOS 都通用，也不用记网卡名：

```sh
ip route get 1.1.1.1        # 默认路由经哪个口出去
ping -c1 deb.debian.org     # 域名能通 → 链路、路由、DNS 都正常
```

然后一行命令装（实现按系统自动选择，VyOS 走用户态）：

```sh
wget -qO- https://raw.githubusercontent.com/FusionPlmH/vep1400-linux-non_dsa-driver/main/get.sh | sudo bash
wget -qO- https://neodev.team/get.sh | sudo bash                     # GitHub 不通时走镜像
```

两行是同一件事，区别只在下载地址；要加参数就在 `bash` 后面接 `-s -- <选项>`（见下表）。
统一用 `wget` 是因为 Debian / Ubuntu / PVE 默认就带（`wget` 是 standard 优先级，
`curl` 是 optional，纯净安装里没有），VyOS 也有；机器上有 `curl` 的话，
`wget -qO-` 换成 `curl -fsSL` 完全等价。

用 git：

```sh
git clone https://github.com/FusionPlmH/vep1400-linux-non_dsa-driver.git
cd vep1400-linux-non_dsa-driver
sudo ./install.sh
```

| 选项 | 作用 |
|---|---|
| *（无）* | 按系统自动选择：Debian/Ubuntu/PVE → 内核模块 + DKMS，VyOS → 用户态 |
| `--userspace` | 强制用户态实现：不编译、不污染内核 |
| `--module` | 强制内核模块（VyOS 上会被拒绝） |
| `--initramfs` | 模块同时进 initramfs（加密根分区、fsck 慢的场景） |
| `--no-dkms` | 只针对当前内核编译 |
| `--no-start` | 装好并 enable，但本次不启动 |
| `--force` | 就地替换已装的另一种实现 |

卸载：`sudo ./uninstall.sh`（模块、`/usr` 下的用户态文件、VyOS 的 `/config` 文件一起清）

## 两种实现怎么选

| | 内核模块 `vep1400.ko` | 用户态 `vep1400-userspace.py` |
|---|---|---|
| Debian / Ubuntu / PVE | **自动选中**（推荐） | `--userspace` 可强制 |
| VyOS 等无编译器系统 | 编不出来 | **自动选中，唯一选择** |
| 内核升级 | DKMS 自动重编 | 不用管 |
| 依赖 | 内核头文件 + 编译器 | `python3` + 可读 `/dev/mem` |
| X553 速率档位 | 可写 | 写不了（本机不需要） |
| 内核污点 | 有 | 无 |

两者驱动同一套寄存器、速率一致，**一台机器只用一种**：`install.sh` 会拒绝混装。

## 支持的系统

| 系统 | `install.sh` 默认选择 | 额外依赖 | 验证状态 |
|---|---|---|---|
| Debian 13 | 内核模块 | `linux-headers-$(uname -r)` + `dkms` | ✅ 实测（13.7 / 内核 6.12） |
| Debian 12 | 内核模块 | 同上 | 预计可用（内核 6.1，未实测） |
| Ubuntu 22.04 / 24.04 | 内核模块 | 同上 | 预计可用（内核 5.15 / 6.8，未实测） |
| Proxmox VE 8 / 9 | 内核模块 | `pve-headers-$(uname -r)` + `dkms` | 预计可用（未实测） |
| VyOS 1.3.4 | 用户态 | `python3` + 可读 `/dev/mem` | ✅ 实测（1.3.4 / 内核 5.4.261） |
| 其它 systemd 发行版 | 用户态 | 同上 | 未实测 |

- 任何系统都可以 `--userspace` 强制用户态：不需要编译器，也不需要内核头文件。
- 硬件只支持 **Dell VEP1400 / VMware SD-WAN Edge 610 非 X（Atom C3308）**。
  Edge 610X / VEP1400-X 用的是 C3558，交换机配置不同，本版本不支持。

## 端口映射

| Linux | 交换端口 | 上行口 | VLAN |
|---|---|---|---|
| `GE1` `GE2` `GE3` | 1 2 3 | `eno1`（03:00.0） | 1 2 3 |
| `GE4` `GE5` `GE6` | 4 5 6 | `eno2`（03:00.1） | 4 5 6 |
| `SFP1` / `SFP2` | — | 05:00.1 / 05:00.0 | 无标签 |

`GE*` 的 MAC 取自对应上行口并加偏移（`+0x0a`…`+0x0f`），保证唯一。

> 上行口的名字随系统不同：Debian / PVE 用 systemd 可预测命名，是 `eno1`/`eno2`
> （SFP 为 `eno3`/`eno4`）；VyOS 用 `net.ifnames=0`，是 `eth0`/`eth1`
> （SFP 为 `eth2`/`eth3`）。

## 使用端口

**Debian / Proxmox VE**（ifupdown）：

```sh
# /etc/network/interfaces
auto GE1
iface GE1 inet dhcp
```

**VyOS**：不接受 `GE1` 这类接口名（会报 `Invalid Ethernet interface name`），要用
两个上行口上的原生 vif —— `vif N` 就是前面板第 N 口：

```
configure
set interfaces ethernet eth0 vif 3 address dhcp     # 前面板 3
set interfaces ethernet eth1 vif 6 address dhcp     # 前面板 6
commit
save
```

两种系统都适用：

- **不要**给上行口本身配地址 —— Debian / PVE 上是 `eno1`/`eno2`，VyOS 上是 `eth0`/`eth1`
- **不要**把两个 `GE*`（VyOS 上是两个 vif）桥接 —— 它们在交换机里本就同广播域，桥接会成环
- 同网段多口是允许的，驱动已给 `GE*` 设好 `arp_ignore=1` / `arp_announce=2`

## 验证

```sh
sudo /usr/lib/vep1400/vep1400-report.sh        # 一页总览
sudo /usr/lib/vep1400/vep1400-linkdiag.sh 3    # 单口自协商解码（两种实现通用）
```

VyOS 上这两个脚本不在 `/usr`（只在 `/config` 里能跨镜像升级保留），直接用工具本身：

```sh
python3 /config/scripts/vep1400-userspace.py info      # 交换机端口表
python3 /config/scripts/vep1400-userspace.py diag 3    # 单口自协商解码
python3 /config/scripts/vep1400-userspace.py watch 60  # 插拔线实时跟踪
```

正常启动的内核日志：

```
vep1400: Marvell 88E6190 rev 1
vep1400: GE1 -> VLAN 1 via CPU port 10
vep1400: CPU port 10 link up (1G)
vep1400: CPU port 9 link up (1G)
vep1400: front panel PHYs powered up, autonegotiation running
vep1400: switch ready
vep1400: GE3 link up (1G)
```

## 排障

先跑 `sudo /usr/lib/vep1400/vep1400-report.sh`（VyOS 用
`python3 /config/scripts/vep1400-userspace.py info`），多数情况它会直接指出问题。

| 现象 | 处理 |
|---|---|
| 没有 `GE1`…`GE6` | `journalctl -u vep1400-net`；模块模式下 `ixgbe` 抢先 probe 时脚本会自动重载一次 |
| 每 4–5 分钟自动重启，或 dmesg 报 `no iSMT SMBus adapter` | 同一个根因：i2c 没起来。`modprobe i2c_ismt`，并确认 `watchdog=1`、服务足够早启动 |
| 某口只到 100M | `vep1400-linkdiag.sh <n>` 看对端是否宣告 1000BASE-T；多半是网线或对端口 |
| `unexpected switch id` | SMI 失步。模块模式看 `dmesg \| grep P2SB` 后传 `p2sb_bar_addr=`；用户态模式确认 `/proc/iomem` 里有 `INTC3000` |
| 内核升级后失效 | 只有模块模式会这样：`dkms status`、`journalctl -u dkms` |

## 硬件

| | |
|---|---|
| 系统 / 主板 | Dell EMC `EDGE610` / `EDGE610-CPU`，BIOS `3.43.0.9-8` |
| CPU | Intel Atom **C3308**（Denverton，2 核 2 线程，1.6 GHz，4 MB L2，含 QAT） |
| 内存 | 4 GB DDR4-2400 ECC，**板载焊死**，不可扩展 |
| 存储 | 16 GB eMMC（板载）+ **mSATA 插槽** + SD 卡槽 |
| LTE | **模块插槽**（选装；参考机那颗 Quectel 是机主自装，走 USB + `cdc_mbim` → `wwan0`） |
| 交换芯片 | Marvell 88E6190 rev 1 |
| 网卡 | 4× Intel X553 Backplane `8086:15c3` |
| 无线 | 参考机 QCA986x（`ath10k_pci`），很适合做管理通道 |
| 前面板 | 6× 10/100/1000BASE-T RJ45，2× SFP |
| 串口 | `ttyS0`，115200 8N1 |
| 散热 | 纯被动，**无风扇**，SMBus 上也没有风扇控制器 |
| 看门狗 | PIC 在 SMBus `0x22`/`0x24`，不关则上电 4–5 分钟强制重启 |

<details>
<summary><b>PHY 初始化做了什么</b></summary>

前面板 PHY 复位后处于**下电**状态（读回来 `BMCR = 0x1940`），所以驱动必须显式上电，
否则永远没有链路。加载时对每个 PHY 写一次：

- DiagOS 的初始化序列（page `0xf8`、reg `0x14`）
- `1000BASE-T 控制 (0x09) = 0x0200`：宣告 1000BASE-T 全双工，master/slave 交给
  自协商决定。板子默认值是 `0x0e00`，其中 bit11 只是「偏好 master」，不影响能否协商
- `BMCR = 0x1140 | AN_RESTART`：上电并启动一次自协商

之后不再写任何 PHY 寄存器，只有只读的链路监视 —— 因为每次写 `BMCR` 都会重启自协商。
有些对端需要 6–12 秒才协商完，这是 1000BASE-T 的正常时间。

若某个口只到 100M，先查**网线和对端端口**：本机实测过劣质网线和一个实际不是千兆的
路由器 LAN 口，两种情况都会落到 100M，与驱动无关。

</details>

<details>
<summary><b>模块参数</b></summary>

在 `/etc/modprobe.d/vep1400.conf` 里设（安装时已生成默认值）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `watchdog` | `1` | 关闭 PIC 看门狗 |
| `sfp_tx` | `1` | 清除两个 SFP 笼的 `TX_DISABLE` |
| `x553_speed` | `1000` | X553 背板档位：`1000`、`2500`、`0`（保留 NVM） |
| `phy_speed` | `0` | `0` 自协商；`10`/`100`/`1000` 强制 |
| `led_init` | `1` | 初始化前面板 LED |
| `bus_num` | `-1` | iSMT 总线号，`-1` 按名字查找 |
| `p2sb_bar_addr` | `0` | P2SB BAR，`0` 自动探测 |

```
softdep ixgbe pre: vep1400
options vep1400 watchdog=1 sfp_tx=1 x553_speed=1000 phy_speed=0 led_init=1
```

`softdep` 很关键：驱动要写 X553 的 `NW_MNG_IF_SEL`，而 `ixgbe` 只在 probe 时读一次。
多数发行版把 `ixgbe` 放进 initramfs，此时 `/sys/kernel/debug/vep1400/info` 会显示
`x553_strap busy`，`vep1400-net.service` 会自动重载一次 `ixgbe`；用 `--initramfs`
安装则可以完全避免这次重载。

</details>

## 目录结构

```
src/                 内核模块：switch / board(i2c) / mdio 头文件
scripts/             netup、teardown、report、linkdiag、userspace 工具
systemd/             vep1400.service、vep1400-net.service（+ 用户态变体）
modprobe/            softdep 与默认参数
initramfs/           可选的提前加载钩子
vyos/                VyOS 安装脚本 + 开机钩子
install.sh           一个入口：默认模块，--userspace 走用户态
get.sh               免 git 的一行命令安装
get-mirror.sh        自建镜像用：归档也只从镜像站取，不碰 GitHub
```

## 许可

GPL-2.0，见 [LICENSE](LICENSE)。寄存器序列来自公开资料和对原厂固件行为的观察，
项目不含 Dell / VMware 代码。
