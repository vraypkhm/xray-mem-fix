#!/usr/bin/env bash
# ============================================================================
#  xray-mem-fix.sh — 256M 小内存代理机 防 OOM / 诊断 / 修复
#
#  场景: 1C / 256M / 无 swap 的 NAT 小鸡, 跑 xray + cloudflared + caddy。
#        高速下载 (20MB/s+) 时 cgroup 里 sock (socket 缓冲) 涨到 140-150MB,
#        加上进程 anon 90MB, 顶穿 256MB 上限, 内核 OOM 掉 PID 1 → 整机停机。
#
#  为什么 swap 救不了: socket 缓冲属于内核内存, 既不可回收也不可换出,
#  swap 再多也搬不动它。唯一有效的方向是**限制单连接缓冲上限**, 让内核
#  提前缩窗口反压发送端, 把数据留在对端而不是留在我们内存里。
#
#  用法 (root):
#     bash xray-mem-fix.sh             # 交互菜单
#     bash xray-mem-fix.sh status      # 只体检, 不改任何东西
#     bash xray-mem-fix.sh apply       # 套用 balanced 档 (推荐起步)
#     bash xray-mem-fix.sh apply 1     # 套用 conservative 档 (最省内存)
#     bash xray-mem-fix.sh apply 2     # 套用 balanced 档 (默认)
#     bash xray-mem-fix.sh apply 4     # 套用 roomy 档 (单流最快, 最易 OOM)
#     bash xray-mem-fix.sh protect     # 让 PID 1 不被 OOM 选中 (关键!)
#     bash xray-mem-fix.sh swap        # 加 512M swap
#     bash xray-mem-fix.sh advice      # 配置层面的减肥建议
#     bash xray-mem-fix.sh revert      # 还原本脚本的全部改动
# ============================================================================

set -uo pipefail

STATE_DIR="/etc/xray-mem-fix"
CREATED_LIST="${STATE_DIR}/created.list"
SYSCTL_FILE="/etc/sysctl.d/99-xray-lowmem.conf"
DROPIN_DIR="/etc/systemd/system"
PROTECT_UNIT="${DROPIN_DIR}/protect-init-oom.service"

R='\033[0m'; RED='\033[1;91m'; GRN='\033[1;32m'
YEL='\033[1;33m'; PUR='\033[1;35m'; BLU='\033[1;36m'
c_red()  { echo -e "${RED}$*${R}"; }
c_grn()  { echo -e "${GRN}$*${R}"; }
c_yel()  { echo -e "${YEL}$*${R}"; }
c_blu()  { echo -e "${BLU}$*${R}"; }
c_pur()  { echo -e "${PUR}$*${R}"; }
pause() {
    printf '\033[1;91m按任意键继续...\033[0m'
    if [ -r /dev/tty ]; then
        read -r -n 1 -s _ </dev/tty
    else
        read -r _ || true
    fi
    echo
}

need_root() {
    [ "$(id -u)" -eq 0 ] || { c_red "请用 root 运行"; exit 1; }
}

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

record_created() {
    mkdir -p "$STATE_DIR"
    grep -qxF "$1" "$CREATED_LIST" 2>/dev/null || echo "$1" >> "$CREATED_LIST"
}

# ============================================================================
#  档位定义
#  每个档位给出 tcp_rmem/tcp_wmem 三元组 (min default max, 单位 byte)。
#
#  换算关系 (为什么是这个数):
#      单流最大吞吐 ≈ 缓冲上限 / RTT
#      conservative: 1MB / 200ms ≈ 5MB/s 单流, 多线程线性叠加
#      balanced    : 2MB / 200ms ≈ 10MB/s 单流
#      roomy       : 4MB / 200ms ≈ 20MB/s 单流
#
#  下载方向是 rx 主导, 所以 tcp_rmem 的 max 决定"下载数据最多在内存里堆多少",
#  tcp_wmem 放到 rmem 的一半就够, 省下来的都算白赚。
# ============================================================================
profile_values() {
    P_WARN=""
    case "$1" in
        1|conservative)
            P_NAME="conservative (最省内存)"
            P_RMEM="4096 65536 1048576"
            P_WMEM="4096 65536 524288"
            P_RMEM_MAX=1048576
            P_WMEM_MAX=524288
            P_TCP_MEM="2048 4096 8192"        # 8MB/16MB/32MB (页 × 4KB)
            P_TSQ=131072                      # 128KB 发送队列积压上限
            P_BDP="1MB 窗口 → 200ms RTT 下单流约 5MB/s"
            ;;
        4|roomy)
            P_NAME="roomy (单流最快)"
            P_RMEM="4096 262144 4194304"
            P_WMEM="4096 131072 2097152"
            P_RMEM_MAX=4194304
            P_WMEM_MAX=2097152
            P_TCP_MEM="6144 12288 24576"      # 24MB/48MB/96MB
            P_TSQ=524288                      # 512KB
            P_BDP="4MB 窗口 → 200ms RTT 下单流约 20MB/s"
            P_WARN="roomy 档在这台 256M 机器上仍然容易 OOM, 只在确认要单流跑满时用"
            ;;
        2|balanced|"")
            P_NAME="balanced (推荐)"
            P_RMEM="4096 131072 2097152"
            P_WMEM="4096 65536 1048576"
            P_RMEM_MAX=2097152
            P_WMEM_MAX=1048576
            P_TCP_MEM="4096 8192 16384"       # 16MB/32MB/64MB
            P_TSQ=262144                      # 256KB
            P_BDP="2MB 窗口 → 200ms RTT 下单流约 10MB/s"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# ============================================================================
#  1. 体检
# ============================================================================
do_status() {
    echo
    c_blu "════════════════ 内存总览 ════════════════"
    free -m
    echo
    c_blu "本地看到的磁盘 swap: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
    [ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ] && \
        c_red "  → 容器内无 swap。注意 sock 内存本来也换不出去, 见下方说明。"

    echo
    c_blu "════════════════ cgroup 内存账本 ════════════════"
    local mb
    mb() { awk '{printf "%.1f MB", $1/1048576}'; }
    if [ -f /sys/fs/cgroup/memory.max ]; then
        echo "cgroup v2   memory.max      : $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
        echo "cgroup v2   memory.high     : $(cat /sys/fs/cgroup/memory.high 2>/dev/null)"
        echo "cgroup v2   memory.current  : $(cat /sys/fs/cgroup/memory.current 2>/dev/null | mb)"
        echo "cgroup v2   memory.swap.max : $(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)"
        echo "cgroup v2   memory.swap.cur : $(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null | mb)"
        echo
        c_blu "--- memory.stat 关键项 (对照你截图里那张表) ---"
        grep -E '^(anon|file|sock|kernel|slab|sock_tcp|sock_tcp6|sock_udp|sock_udp6|sock_tcp_from_anon) ' \
             /sys/fs/cgroup/memory.stat 2>/dev/null \
          | awk '{printf "  %-12s %9.1f MB\n", $1, $2/1048576}'
        c_yel "  ↑ sock = socket 缓冲, 内核内存, 不可回收不可换出。这一项失控就是 OOM 的直接原因。"
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        echo "cgroup v1   limit_in_bytes  : $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
        c_blu "--- memory.stat 关键项 ---"
        grep -E '^(total_rss|total_cache|total_sock|total_slab|total_sock_tcp) ' \
             /sys/fs/cgroup/memory/memory.stat 2>/dev/null \
          | awk '{printf "  %-14s %9.1f MB\n", $1, $2/1048576}'
    else
        c_yel "没找到 cgroup memory 接口 (可能不在容器里)"
    fi

    echo
    c_blu "════════════════ 网络栈缓冲现状 ════════════════"
    c_yel "max 越大, 高速下载时数据在内存里堆得越多。当前值:"
    printf "  %-34s = %s\n" "net.ipv4.tcp_rmem"        "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "  %-34s = %s\n" "net.ipv4.tcp_wmem"        "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    printf "  %-34s = %s\n" "net.ipv4.tcp_mem(页)"     "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)"
    printf "  %-34s = %s\n" "net.core.rmem_max"        "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf "  %-34s = %s\n" "net.core.wmem_max"        "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf "  %-34s = %s\n" "net.ipv4.tcp_moderate_rcvbuf" "$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null)"
    printf "  %-34s = %s\n" "net.ipv4.tcp_adv_win_scale"   "$(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null)"
    printf "  %-34s = %s\n" "net.ipv4.tcp_notsent_lowat"   "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
    printf "  %-34s = %s\n" "vm.min_free_kbytes"       "$(sysctl -n vm.min_free_kbytes 2>/dev/null)"
    printf "  %-34s = %s\n" "vm.panic_on_oom"          "$(sysctl -n vm.panic_on_oom 2>/dev/null)"

    echo
    c_blu "════════════════ 实测 sock 占用 ════════════════"
    if command -v ss >/dev/null 2>&1; then
        ss -tmn -a 2>/dev/null | grep -oE '(rb|tb)[0-9]+' \
          | awk '{s += substr($0,3)} END{printf "  全机 TCP 收发缓冲合计: %.1f MB\n", s/1048576}'
        echo
        c_blu "--- 缓冲占用 Top8 的连接 ---"
        ss -tmn -a 2>/dev/null \
          | awk '/skmem:/{
                n=split($0,a,"skmem:\\("); rest=a[n];
                br=0; bw=0;
                gsub(/[(),]/," ",rest); m=split(rest,f," ");
                for(i=1;i<=m;i++){ if(f[i]~/^rb[0-9]/){br=substr(f[i],3)+0} if(f[i]~/^tb[0-9]/){bw=substr(f[i],3)+0} }
                if(br+bw>65536) printf "%7.1f MB  %s\n", (br+bw)/1048576, $0
            }' | sort -rn | head -8
        echo
        c_blu "--- 代理端口上的在建连接数 (每条连接至少 2 个 socket) ---"
        for p in 8080 3001 3002 3003; do
            local n
            n=$(ss -tn state established "sport = :$p or dport = :$p" 2>/dev/null | tail -n +2 | wc -l)
            [ "$n" -gt 0 ] && printf "  端口 %-5s : %s 条\n" "$p" "$n"
        done
    else
        c_yel "  ss 未安装 (apt install -y iproute2)"
    fi

    echo
    c_blu "════════════════ 进程占用 Top10 ════════════════"
    ps aux --sort=-rss 2>/dev/null | head -11 \
      | awk 'NR==1{print "  USER     RSS(MB)  进程"} NR>1{printf "  %-8s %7.1f  %s\n", $1, $6/1024, $11}'

    echo
    c_blu "════════════════ OOM 防护是否到位 ════════════════"
    local adj1
    adj1=$(cat /proc/1/oom_score_adj 2>/dev/null)
    if [ -n "$adj1" ] && [ "$adj1" -lt 0 ] 2>/dev/null; then
        c_grn "  PID1 oom_score_adj = $adj1  → 内核不会再优先杀 init"
    else
        c_red "  PID1 oom_score_adj = ${adj1:-?}  → init 是合法靶子, 一被杀整机就停"
        c_yel "  修: bash $0 protect"
    fi
    local u cap
    for u in xray tunnel caddy; do
        systemctl cat "$u.service" >/dev/null 2>&1 || continue
        cap=$(systemctl show -p MemoryMax --value "$u" 2>/dev/null)
        if [ -n "$cap" ] && [ "$cap" != "infinity" ]; then
            c_grn "  ${u}.service MemoryMax=$cap 已生效"
        else
            c_yel "  ${u}.service MemoryMax 未设置"
        fi
    done

    echo
    c_blu "════════════════ 最近一次 OOM 取证 ════════════════"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -k --no-pager 2>/dev/null | grep -E 'invoked oom-killer|oom-kill:|Out of memory' | tail -12
    fi
    [ -r /var/log/kern.log ] && grep -E 'invoked oom-killer|Out of memory' /var/log/kern.log 2>/dev/null | tail -5
    echo
    c_yel "  若上面为空: 平台把内核日志藏了, 或 dmesg 受限。用截图那份就够了。"
    echo
    c_blu "════════════════ 本脚本改动状态 ════════════════"
    [ -f "$SYSCTL_FILE" ] && c_grn "  已写入 $SYSCTL_FILE" || c_yel "  未写入 sysctl 调优"
    [ -f "$PROTECT_UNIT" ] && c_grn "  已安装 init OOM 保护" || c_yel "  未安装 init OOM 保护"
    echo
}

# ============================================================================
#  2. 套用 sysctl 调优
# ============================================================================
do_apply() {
    need_root
    profile_values "${1:-2}" || { c_red "档位只能是 1 / 2 / 4"; return 1; }
    mkdir -p "$STATE_DIR" /etc/sysctl.d

    echo
    c_blu "════════ 档位: ${P_NAME} ════════"
    c_yel "  ${P_BDP}"
    echo
    c_yel "  原理: 内核默认 tcp_rmem max=6MB / tcp_wmem max=4MB, 意味着单条连接"
    c_yel "        最多可以把 10MB 数据压在内存里。xray 转发一条流要占 2 个 socket"
    c_yel "        (上游 recv + 下游 send), 所以一条 20MB/s 的流最多能占 20MB。"
    c_yel "        并发 8 条就是 160MB —— 正好对得上你截图里的 sock 150MB。"
    c_yel ""
    c_yel "        把 max 压小后, 内核会提前缩窗口, 数据留在对端而不是我们这边。"
    c_yel "        代价是单流峰值下降 (见上面的 BDP 换算), 多线程下载可线性补回。"
    [ -n "${P_WARN:-}" ] && c_red "  ⚠ ${P_WARN}"
    echo

    cat > "$SYSCTL_FILE" <<EOF
# ---------------------------------------------------------------------------
# 由 xray-mem-fix.sh 生成 — 小内存代理机防 OOM  (档位: ${P_NAME})
# 删除本文件即可还原: rm ${SYSCTL_FILE} && sysctl --system
# ---------------------------------------------------------------------------

# --- 单 socket 收发缓冲上限: 本方案最核心的一项 -------------------------
# 格式 min default max (byte)。max 是内核自动调优的天花板。
net.ipv4.tcp_rmem = ${P_RMEM}
net.ipv4.tcp_wmem = ${P_WMEM}

# 保留自动调优(1)。置 0 会钉死在 default 上, 省内存但吞吐掉得厉害;
# 天花板已由上面的 max 兜住, 调优涨不过 max。
net.ipv4.tcp_moderate_rcvbuf = 1

# 窗口缩放: 1 = 广告窗口扣掉一半给应用层, 比 0 更保守。小机器保持默认。
net.ipv4.tcp_adv_win_scale = 1

# 发送队列里未发出的数据低于此值时立刻推包, 减少积压
net.ipv4.tcp_notsent_lowat = 16384

# --- 全局 TCP 内存硬预算 (页, 1页=4KB) ----------------------------------
# 格式: low pressure high。越过 high 后内核丢包而不是继续吃内存。
net.ipv4.tcp_mem = ${P_TCP_MEM}

# --- 单 socket 发送队列积压上限 (TSQ) -----------------------------------
# 默认 1MB。转发场景下这是 sock 内存最凶的一项: 客户端慢一点,
# 数据就全堆在发送队列里。压到 256KB, 队列满了直接反压上游, 不堆内存。
net.ipv4.tcp_limit_output_bytes = ${P_TSQ}

# --- 每 socket 辅助缓冲 (cmsg / 小分配) ---------------------------------
net.core.optmem_max = 8192

# --- TIME_WAIT 积压上限: 每个 tw 连接都占一个 sock 结构 ------------------
net.ipv4.tcp_max_tw_buckets = 8192

# --- 单 socket 绝对上限 (与上面 max 保持一致) ---------------------------
net.core.rmem_max = ${P_RMEM_MAX}
net.core.wmem_max = ${P_WMEM_MAX}
net.core.rmem_default = 65536
net.core.wmem_default = 65536

# --- 队列与连接数 ------------------------------------------------------
# 收包队列太长会在软中断里堆 skb (同样记在 sock 名下)
net.core.netdev_max_backlog = 1000
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 60999

# --- 内核内存回收 ------------------------------------------------------
# 给内核留的紧急内存; 太小会在分配失败时直接 OOM
vm.min_free_kbytes = 16384
# 更积极回收 page cache, 把 RAM 让给 sock/slab
vm.vfs_cache_pressure = 200
vm.swappiness = 60
vm.overcommit_memory = 0
# OOM 时只杀进程, 千万不要 panic (容器里 panic = 直接停机)
vm.panic_on_oom = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

    [ -f "$SYSCTL_FILE" ] && record_created "$SYSCTL_FILE"
    if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        c_grn "  ✔ sysctl 已写入并生效"
    else
        c_red "  ✘ 部分参数没写进去 (很多托管容器会把 net.* 设成只读)"
        c_yel "    逐条重试看是哪一项?"
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            local k v
            k=${line%%=*}; k=$(echo "$k" | tr -d ' ')
            v=${line#*=}; v=$(echo "$v" | tr -s ' ')
            sysctl -w "${k}=${v}" >/dev/null 2>&1 || c_yel "      ✘ 无法设置 ${k}"
        done < "$SYSCTL_FILE"
        c_yel "    能设的都设了, 设不了的通常是容器 sysctl 白名单限制, 只能换机器/找服务商放开。"
    fi

    echo
    c_blu "--- 验证 ---"
    printf "  tcp_rmem = %s\n" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "  tcp_wmem = %s\n" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    printf "  tcp_mem  = %s\n" "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)"
    echo
    c_grn "sysctl 立即生效, 不需要重启服务。"
    echo
}

# ============================================================================
#  3. 保护 PID 1 —— 这是「整机停机」和「服务重启」的分水岭
# ============================================================================
do_protect() {
    need_root
    echo
    c_blu "════════ 让 OOM killer 不再选 init ════════"
    c_yel "你截图里两次被杀的对象都是 init (PID 3600118 / 412162), 不是 xray。"
    c_yel "内核挑人时按 oom_score 排序, init 在容器里通常是最高分之一 ——"
    c_yel "一旦它被选中, 容器里所有服务跟着死, 而且没有东西会把它拉起来。"
    c_yel ""
    c_yel "把 PID1 的 oom_score_adj 压到负值, 内核就会转而杀掉真正吃内存的"
    c_yel "那个进程 (xray / cloudflared)。配合 Restart=on-failure, 服务自动回来,"
    c_yel "容器继续活着 —— 你只会看到一次短暂断流, 而不是关机。"
    echo

    local cur target ok=""
    cur=$(cat /proc/1/oom_score_adj 2>/dev/null)
    c_blu "  当前 PID1 oom_score_adj = ${cur:-未知}"

    for target in -900 -500 -100; do
        if echo "$target" > /proc/1/oom_score_adj 2>/dev/null; then
            ok="$target"; break
        fi
    done

    if [ -z "$ok" ]; then
        c_red "  ✘ 写不进去 (缺 CAP_SYS_RESOURCE)。这一层用不了。"
        c_yel "    只能靠 sysctl 限缓冲 + 下面给服务加 MemoryMax 来顶。"
        return 1
    fi
    c_grn "  ✔ 写入成功: oom_score_adj = $(cat /proc/1/oom_score_adj)"

    # 持久化: 容器重启后 PID1 的 adj 会重置, 用 oneshot 早期设一次
    mkdir -p "$STATE_DIR"
    cat > "$PROTECT_UNIT" <<EOF
# 由 xray-mem-fix.sh 生成 — 保护容器 init 不被 OOM killer 选中
# 删除: rm ${PROTECT_UNIT} && systemctl daemon-reload
[Unit]
Description=Protect container init from OOM killer
DefaultDependencies=no
After=sysinit.target
Before=shutdown.target
ConditionPathExists=/proc/1/oom_score_adj

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo ${ok} > /proc/1/oom_score_adj 2>/dev/null || echo -100 > /proc/1/oom_score_adj 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    record_created "$PROTECT_UNIT"
    if have_systemd; then
        systemctl daemon-reload 2>/dev/null
        if systemctl enable --now protect-init-oom.service >/dev/null 2>&1; then
            c_grn "  ✔ 已安装开机自启单元 protect-init-oom.service"
        else
            c_yel "  ⚠ 单元没启用成功 (容器里 systemd 可能受限), 但当前进程已生效。"
            c_yel "    重启容器后需要手动再跑一次: bash \$0 protect"
        fi
    else
        c_yel "  没有运行中的 systemd, 改用 /etc/rc.local 持久化"
        if [ -f /etc/rc.local ] || { printf '#!/bin/sh\nexit 0\n' > /etc/rc.local && chmod +x /etc/rc.local; }; then
            grep -q 'oom_score_adj' /etc/rc.local 2>/dev/null || \
                sed -i "/^exit 0/i echo ${ok} > /proc/1/oom_score_adj 2>/dev/null || true" /etc/rc.local
            c_grn "  已写入 /etc/rc.local"
        fi
    fi

    echo
    c_yel "  注意: 这不能减少内存占用, 只是改变\"谁去死\"。"
    c_yel "  真正的减负还得靠 apply 里的缓冲上限 + advice 里的关入站。"
    echo
}

# ============================================================================
#  4. 给服务加 cgroup 内存上限
# ============================================================================
do_limits() {
    need_root
    echo
    c_blu "════════ 给三个守护进程加内存上限 ════════"
    if ! have_systemd; then
        c_red "  没有运行中的 systemd (openrc / 裸进程), 这一层用不了。"
        c_yel "  跳过, 只靠 sysctl + protect 两道防线。"
        echo
        return 0
    fi
    c_yel "sock 缓冲记在持有它的进程 cgroup 名下, 所以压完 tcp_rmem 之后"
    c_yel "xray 自己的 cgroup 也会一起瘦下来。这里再加一层:"
    c_yel "  MemoryHigh 软限 → 到线优先回收/压缩, 不杀进程"
    c_yel "  MemoryMax  硬限 → 真到线只杀这一个服务, systemd 立刻拉起"
    c_yel "上限给到正常占用 2 倍以上, 正常吞吐根本碰不到。"
    echo

    write_dropin() {
        local unit="$1" high="$2" max="$3" extra="$4"
        local dir="${DROPIN_DIR}/${unit}.d"
        local file="${dir}/50-lowmem.conf"
        if ! systemctl cat "${unit}" >/dev/null 2>&1; then
            c_yel "  跳过 ${unit} (未安装)"
            return 0
        fi
        mkdir -p "$dir"
        cat > "$file" <<EOF
# 由 xray-mem-fix.sh 生成 — 小内存防 OOM
# 删除: rm ${file} && systemctl daemon-reload
[Service]
MemoryHigh=${high}
MemoryMax=${max}
MemorySwapMax=0
${extra}
EOF
        record_created "$file"
        c_grn "  写入 ${file}  (MemoryHigh=${high} MemoryMax=${max})"
    }

    c_blu "--- 内存预算分配 (容器上限 256M, 内核/slab 占 ~12M) ---"
    echo "  可用 ≈ 244M, 三个服务的 MemoryMax 加起来必须小于它,"
    echo "  否则三个同时顶格 = 容器整体 OOM, 等于白设。"
    echo "    xray   : high  88M / max 128M"
    echo "    tunnel : high  40M / max  56M"
    echo "    caddy  : high  28M / max  40M"
    echo "    ─────────────────────────────"
    echo "    合计 max = 224M < 244M  ✔"
    echo
    write_dropin "xray.service"   "88M"  "128M" $'TasksMax=512\nLimitNOFILE=65535\nEnvironment=GOGC=30\nEnvironment=GOMEMLIMIT=64MiB'
    write_dropin "tunnel.service" "40M"  "56M"  $'TasksMax=256\nLimitNOFILE=65535\nEnvironment=GODEBUG=madvdontneed=1\nEnvironment=GOGC=40\nEnvironment=GOMEMLIMIT=24MiB'
    write_dropin "caddy.service"  "28M"  "40M"  'TasksMax=256'

    systemctl daemon-reload 2>/dev/null && c_grn "  daemon-reload 完成"

    echo
    c_blu "--- 验证是否被 systemd 接管 ---"
    local u cap
    for u in xray tunnel caddy; do
        systemctl cat "${u}.service" >/dev/null 2>&1 || continue
        cap=$(systemctl show -p MemoryMax --value "$u" 2>/dev/null)
        if [ -n "$cap" ] && [ "$cap" != "infinity" ]; then
            c_grn "  ${u}: MemoryMax=${cap}"
        else
            c_red "  ${u}: MemoryMax 仍为 infinity"
            c_yel "    容器多半没把 memory 控制器委托给 systemd。检查:"
            c_blu "      cat /sys/fs/cgroup/cgroup.controllers"
            c_blu "      cat /sys/fs/cgroup/cgroup.subtree_control"
            c_yel "    这层保险失效不影响系统, 但只剩 sysctl 一道防线。"
        fi
    done

    echo
    c_yel "限额要重启服务才接管:"
    c_blu "  systemctl restart xray tunnel caddy"
    c_red "  注意: 重启 xray 会掐断当前所有连接, 挑没人的时候做。"
    echo
}

# ============================================================================
#  5. swap
# ============================================================================
do_swap() {
    need_root
    local swapfile="/swapfile" size_mb=512
    echo
    c_blu "════════ 添加 ${size_mb}MB swap ════════"
    c_yel "先说清楚: swap 对 sock 内存无效 (内核内存不可换出)。"
    c_yel "它的作用是兜住 anon 那 90MB, 避免进程内部小峰值直接顶穿。"
    c_yel "属于第二道保险, 不是主药。"
    echo

    if [ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]; then
        c_grn "  已有 swap: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
        return 0
    fi

    local fstype avail
    fstype=$(df -PT / 2>/dev/null | awk 'NR==2{print $2}')
    echo "  根分区文件系统: ${fstype:-未知}"
    case "$fstype" in
        tmpfs|ramfs)
            c_red "  ✘ 根分区是 ${fstype} —— 写 swap 文件等于写进内存, 会死得更快。"
            c_red "    放弃。请用服务商面板开 swap, 或把 swap 放真实磁盘。"
            return 1 ;;
    esac

    avail=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail" ] && [ "$avail" -lt $((size_mb + 512)) ]; then
        c_red "  ✘ 磁盘可用 ${avail}MB, 不够 ${size_mb}MB + 余量。放弃。"
        return 1
    fi

    if [ ! -f "$swapfile" ]; then
        c_yel "  创建 ${swapfile} ..."
        if ! fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null; then
            c_yel "  fallocate 不支持, 改用 dd (慢一些)"
            dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" 2>/dev/null || {
                c_red "  dd 失败"; rm -f "$swapfile"; return 1; }
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null || { c_red "  mkswap 失败"; return 1; }
    fi

    if ! swapon "$swapfile" 2>/dev/null; then
        c_red "  ✘ swapon 失败 —— 容器缺 CAP_SYS_ADMIN, 这是常见限制。"
        c_red "    清理半成品: rm -f ${swapfile}"
        rm -f "$swapfile"
        c_yel "    改用服务商面板开 swap。"
        return 1
    fi

    grep -qF "$swapfile" /etc/fstab 2>/dev/null || echo "$swapfile none swap sw 0 0" >> /etc/fstab
    c_grn "  ✔ swap 已启用, 并写入 /etc/fstab"
    swapon --show
    echo
}

# ============================================================================
#  6. 配置层面减肥 (只打印, 不动配置)
# ============================================================================
do_advice() {
    echo
    c_blu "════════ 比调参收益更大的几件事 ════════"

    c_grn ""
    c_grn "① 关掉用不上的 argo 隧道 —— 优先级最高"
    echo "   你现在的 config.json 开了 6 个入站 (8080 / 3001 / 3002 / 3003 /"
    echo "   xhttp-reality / grpc-reality), argo 那 4 个叠了 cloudflared + caddy"
    echo "   两个完整进程, 而两次 OOM 的触发进程分别是 argo 和 xray,"
    echo "   说明两条链路都在贡献 sock 压力。只用 Reality 的话:"
    echo
    c_blu "     systemctl stop tunnel && systemctl disable tunnel"
    echo
    echo "   然后从 /etc/xray/config.json 删掉 8080 / 3001 / 3002 / 3003 四个入站,"
    echo "   只留 xhttp-reality 和 grpc-reality。启动脚本里的 fallbacks 也要一并删,"
    echo "   否则 xray 启动会因 dest 不存在而报错。"
    echo "   省下 cloudflared 常驻 ~40MB + 每个 WS 连接的双份缓冲。"

    c_grn ""
    c_grn "② 关掉 sniffing"
    echo "   你有 3 个入站写了 \"sniffing\": {\"destOverride\": [\"http\",\"tls\",\"quic\"]}。"
    echo "   它会对每条连接做协议嗅探, 在 1 核机器上既吃 CPU 也让连接多留一份"
    echo "   元数据。除非你要按域名分流, 否则删掉整块 sniffing, 只保留"
    echo "   \"sniffing\": {\"enabled\": false}。"
    echo "   省 5-15MB 且降低 CPU 抖动。"

    c_grn ""
    c_grn "③ 不要在同一台机器再跑 sing-box 四合一"
    echo "   脚本菜单第 9 项会再装一套 sing-box。xray + cloudflared + caddy +"
    echo "   sing-box 常驻合计 120-160MB, 留给 socket 缓冲的只剩 100MB 出头,"
    echo "   20MB/s 跑不了几秒。这台机器已经在极限上, 加不了东西。"

    c_grn ""
    c_grn "④ 客户端侧限制并发线程数"
    echo "   IDM / aria2 / 浏览器多线程下载, 每个连接都是一份独立缓冲。"
    echo "   256M 的机器上建议线程数 4-8, 不要 32 线程。这比改服务端配置"
    echo "   省事得多, 而且立刻见效。"

    c_grn ""
    c_grn "⑤ 真想吃满 20MB/s, 就该换机器"
    echo "   算笔账: 20MB/s 双程转发, 每条流 2 个 socket, 想稳住至少需要"
    echo "   60-80MB 的 socket 缓冲预算。256MB 的机器连 anon 都占掉 90MB,"
    echo "   物理上没有余量。1C512M 或 1C1G 的机器成本差不多, 直接根治。"

    c_grn ""
    c_grn "⑥ 让平台侧对 OOM 做自动重启"
    echo "   这次是 PID 1 被杀导致整机停机, 而且第二次之后没人拉起来 ——"
    echo '   这才是你「睡一觉发现机器没了」的直接原因。我们这边能做的都做了,'
    echo "   但至少要让平台在容器死亡后自动重启, 否则半夜断线你都不知道。"
    c_yel "   (这条只能找服务商, 容器里改不了)"
    echo
}

# ============================================================================
#  7. 还原
# ============================================================================
do_revert() {
    need_root
    echo
    c_yel "开始还原 xray-mem-fix 的改动..."
    echo
    if [ -f "$CREATED_LIST" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            if [ -e "$f" ]; then
                rm -f "$f" && c_grn "  已删除 ${f}"
                rmdir "$(dirname "$f")" 2>/dev/null || true
            fi
        done < "$CREATED_LIST"
    fi
    [ -f "$SYSCTL_FILE" ] && rm -f "$SYSCTL_FILE" && c_grn "  已删除 ${SYSCTL_FILE}"

    systemctl disable --now protect-init-oom.service >/dev/null 2>&1 || true
    systemctl daemon-reload 2>/dev/null
    sysctl --system >/dev/null 2>&1
    c_grn "  已重新加载系统 sysctl"

    echo
    c_yel "如需移除 swap:"
    c_blu "  swapoff /swapfile && sed -i '/\\/swapfile/d' /etc/fstab && rm -f /swapfile"
    echo
    c_yel "如需让服务丢掉 cgroup 限额:"
    c_blu "  systemctl restart xray tunnel caddy"
    echo
}

# ============================================================================
#  8. 一键做全套
# ============================================================================
do_all() {
    need_root
    do_apply "${1:-2}"
    do_protect
    do_limits
    echo
    c_blu "════════ 全套完成 ════════"
    c_yel "还剩一步需要你手动执行 (会断流, 挑没人的时候):"
    c_blu "  systemctl restart xray tunnel caddy"
    echo
    c_yel "之后跑 bash $0 status 复核。"
    echo
    do_advice
}

# ============================================================================
#  菜单
# ============================================================================
menu() {
    while true; do
        clear
        c_blu "╔══════════════════════════════════════════════╗"
        c_blu "║   xray-mem-fix  —  256M 小鸡防 OOM           ║"
        c_blu "╚══════════════════════════════════════════════╝"
        echo
        c_grn "  1. 体检 (只读, 不改任何东西)"
        c_grn "  2. 一键全套 (调优 + 保护 init + 限额)   ← 推荐"
        echo "  ─────────────────────────────"
        c_grn "  3. 只调 sysctl 缓冲 (conservative 1MB)"
        c_grn "  4. 只调 sysctl 缓冲 (balanced 2MB)"
        c_grn "  5. 只调 sysctl 缓冲 (roomy 4MB)"
        c_grn "  6. 只保护 PID 1 不被 OOM 选中"
        c_grn "  7. 只给服务加 cgroup 内存上限"
        echo "  ─────────────────────────────"
        c_grn "  8. 添加 512MB swap"
        c_grn "  9. 看配置减肥建议 (关 argo / 关 sniffing)"
        echo "  ─────────────────────────────"
        c_red " 10. 还原全部改动"
        c_yel "  0. 退出"
        echo
        printf '\033[1;91m请输入选择: \033[0m'
        read -r choice
        case "${choice}" in
            1)  do_status;  pause ;;
            2)  do_all 2;   pause ;;
            3)  do_apply 1; pause ;;
            4)  do_apply 2; pause ;;
            5)  do_apply 4; pause ;;
            6)  do_protect; pause ;;
            7)  do_limits;  pause ;;
            8)  do_swap;    pause ;;
            9)  do_advice;  pause ;;
            10) do_revert;  pause ;;
            0)  exit 0 ;;
            *)  c_red "无效选项"; sleep 1 ;;
        esac
    done
}

main() {
    need_root
    local action="${1:-}"
    case "$action" in
        status)    do_status ;;
        apply)     do_apply "${2:-2}" ;;
        protect)   do_protect ;;
        limits)    do_limits ;;
        swap)      do_swap ;;
        advice)    do_advice ;;
        revert)    do_revert ;;
        all)       do_all "${2:-2}" ;;
        "")        menu ;;
        -h|--help|help)
            sed -n '2,30p' "$0" ;;
        *)  c_red "未知操作: ${action}"
            echo "用法: bash $0 [status|apply [1|2|4]|protect|limits|swap|advice|revert|all]"
            exit 1 ;;
    esac
}

main "$@"
