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
#     bash xray-mem-fix.sh cgroup      # 设 cgroup 软限 (sysctl 被锁时的替代)
#     bash xray-mem-fix.sh swap        # 加 512M swap
#     bash xray-mem-fix.sh advice      # 配置层面的减肥建议
#     bash xray-mem-fix.sh watch       # 前台采样 sock/内存曲线 (只读)
#     bash xray-mem-fix.sh revert      # 还原本脚本的全部改动
# ============================================================================

set -uo pipefail

STATE_DIR="/etc/xray-mem-fix"
CREATED_LIST="${STATE_DIR}/created.list"
SYSCTL_DIR="/etc/sysctl.d"
SYSCTL_FILE="${SYSCTL_DIR}/99-xray-lowmem.conf"
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

# 字节数转人类可读, 未知名返回 "-"
h_mb() {
    case "${1:-}" in ''|max|n/a) echo "-"; return ;; esac
    awk -v v="$1" 'BEGIN{ if (v >= 1073741824) printf "%.2f GB", v/1073741824; else printf "%.1f MB", v/1048576 }'
}

# 读 cgroup 文件; 不存在或内容为 max 时返回空串
cg_read() {
    [ -r "$1" ] || return 0
    local v; v=$(cat "$1" 2>/dev/null)
    [ "$v" = "max" ] || printf '%s' "$v"
}

# 按 RSS 列进程, 不依赖 ps 的 aux/sort 扩展 (busybox 上没有)
# PROC_ROOT 仅供自测注入, 生产环境恒为 /proc
proc_top_by_rss() {
    local root="${PROC_ROOT:-/proc}"
    local d rss name pid _a _b _c
    for d in "$root"/[0-9]*; do
        [ -r "$d/statm" ] || continue
        read -r _a rss _b _c < "$d/statm" 2>/dev/null || continue
        [ -n "${rss:-}" ] || continue
        rss=$(( rss * 4 ))
        [ "$rss" -ge 2048 ] || continue
        pid=${d#"$root"/}
        name=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-40)
        [ -n "$name" ] || name=$(cat "$d/comm" 2>/dev/null)
        [ -n "$name" ] || name="(kernel)"
        printf "%9d KB  %-40s %s\n" "$rss" "$name" "$pid"
    done | sort -rn | head -10
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
    c_blu "════════════════ 一、内存总览 (以 cgroup 为准) ════════════════"

    local cg="" ver="" mx="" cur="" hi="" swmx="" swcur="" peak=""
    if [ -f /sys/fs/cgroup/memory.max ]; then
        cg=/sys/fs/cgroup; ver=v2
        mx=$(cg_read "$cg/memory.max");   hi=$(cg_read "$cg/memory.high")
        cur=$(cg_read "$cg/memory.current"); peak=$(cg_read "$cg/memory.peak")
        swmx=$(cg_read "$cg/memory.swap.max"); swcur=$(cg_read "$cg/memory.swap.current")
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cg=/sys/fs/cgroup/memory; ver=v1
        mx=$(cg_read "$cg/memory.limit_in_bytes")
        cur=$(cg_read "$cg/memory.usage_in_bytes")
        peak=$(cg_read "$cg/memory.max_usage_in_bytes")
    fi

    if [ -n "$mx" ]; then
        local pct=0 mbmax
        mbmax=$(( mx / 1048576 ))
        [ "$mx" -gt 0 ] && [ -n "$cur" ] && pct=$(( cur * 100 / mx ))
        printf "  容器内存上限 : %s\n" "$(h_mb "$mx")"
        printf "  当前占用     : %-12s (%s%%)\n" "$(h_mb "$cur")" "$pct"
        printf "  历史峰值     : %s\n" "$(h_mb "$peak")"
        if [ "$ver" = v2 ]; then
            if [ -n "$hi" ]; then printf "  软限 high    : %s\n" "$(h_mb "$hi")"
            else printf "  软限 high    : %s\n" "max (未设软限, 只能等撞硬限)"; fi
            printf "  swap 上限    : %s (已用 %s)\n" \
                   "$( [ -n "$swmx" ] && h_mb "$swmx" || echo '0 → 已禁用' )" "$(h_mb "$swcur")"
        fi
        if [ "$pct" -ge 80 ]; then
            c_red "  ⚠ 已用 ${pct}%, 再涨就撞上限。第二、三节是重点。"
        elif [ "$pct" -ge 60 ]; then
            c_yel "  用量偏高, 有空跑一次 apply。"
        else
            c_grn "  当前水位安全。"
        fi

        # free 在容器里读到的往往是宿主机数字, 别被它误导
        local ftotal
        ftotal=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
        if [ -n "$ftotal" ] && [ "$ftotal" -gt $(( mbmax * 2 )) ]; then
            echo
            c_yel "  ⚠ free 显示的 ${ftotal}MB 是【宿主机】内存, 不是你能用的。"
            c_yel "    容器真实上限 ${mbmax}MB —— 下面所有判断都以 cgroup 为准。"
        fi
    else
        c_yel "  没读到 cgroup memory 限额 (不在容器里, 或 cgroup 未挂载)"
    fi

    echo
    c_blu "════════════════ 二、cgroup 内存账本 (对照你截图那张表) ════════════════"
    local statf=""
    [ "$ver" = v2 ] && statf=/sys/fs/cgroup/memory.stat
    [ "$ver" = v1 ] && statf=/sys/fs/cgroup/memory/memory.stat
    if [ -r "$statf" ]; then
        awk '{
            v[$1]=$2
        }
        END{
            split("anon file kernel slab sock sock_tcp sock_tcp6 sock_udp pagetables kernel_stack percpu shmem file_mapped", want, " ")
            for (i=1; i<=12; i++) {
                k=want[i]
                if (v[k] != "") printf "  %-14s %8.1f MB\n", k, v[k]/1048576
            }
        }' "$statf"
        local sockb
        sockb=$(awk '$1=="sock"{print $2}' "$statf" 2>/dev/null)
        if [ -n "$sockb" ] && [ "$sockb" -gt 0 ] 2>/dev/null; then
            local spct=0
            [ -n "$mx" ] && [ "$mx" -gt 0 ] && spct=$(( sockb * 100 / mx ))
            if [ "$spct" -ge 25 ]; then
                c_red "  ↑ sock 占了全容器 ${spct}% —— 这就是 OOM 的直接来源, 用 apply 压 tcp_rmem。"
            else
                c_yel "  ↑ sock = socket 缓冲, 内核内存, 不可回收、不可换出。"
            fi
        else
            c_yel "  ↑ sock = socket 缓冲, 内核内存, 不可回收、不可换出。"
        fi
    fi

    echo
    c_blu "════════════════ 三、网络栈缓冲现状 ════════════════"
    local rmax wmax
    rmax=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    wmax=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    printf "  %-32s = %s\n" "net.ipv4.tcp_rmem" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf "  %-32s = %s\n" "net.ipv4.tcp_wmem" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    if [ -n "$rmax" ] && [ "$rmax" -ge 8388608 ] 2>/dev/null; then
        c_red "  ↑ 单流接收上限 $(h_mb "$rmax")。一条转发流两个 socket, 并发 5 条就能吃 ${mbmax:-256}MB 里的 160MB。"
        c_red "    这正是你截图里 sock 150MB 的来源 —— 跑 apply 压到 2MB。"
    fi
    printf "  %-32s = %s\n" "net.ipv4.tcp_mem(页)" "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)"
    [ -z "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null)" ] && \
        c_yel "  ↑ 读不到: 容器通常没把 tcp_mem 暴露出来 (它只影响全局, 影响不大)。"
    printf "  %-32s = %s\n" "net.core.rmem_max" "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    printf "  %-32s = %s\n" "net.core.wmem_max" "$(sysctl -n net.core.wmem_max 2>/dev/null)"
    printf "  %-32s = %s\n" "net.ipv4.tcp_moderate_rcvbuf" "$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null)"
    printf "  %-32s = %s\n" "net.ipv4.tcp_adv_win_scale"   "$(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null)"
    printf "  %-32s = %s\n" "net.ipv4.tcp_limit_output_bytes" "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)"
    printf "  %-32s = %s\n" "net.ipv4.tcp_notsent_lowat"   "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
    printf "  %-32s = %s\n" "vm.min_free_kbytes"       "$(sysctl -n vm.min_free_kbytes 2>/dev/null)"
    printf "  %-32s = %s\n" "vm.panic_on_oom"          "$(sysctl -n vm.panic_on_oom 2>/dev/null)"

    echo
    c_blu "════════════════ 四、实测 socket 占用 ════════════════"
    if command -v ss >/dev/null 2>&1; then
        ss -tanm 2>/dev/null | awk '
            /^[ \t]*skmem:/ {
                line=$0; gsub(/[(),]/," ",line); n=split(line,f," ")
                rb=0; tb=0
                for (i=1;i<=n;i++) {
                    if (f[i] ~ /^rb[0-9]+$/) rb=substr(f[i],3)+0
                    if (f[i] ~ /^tb[0-9]+$/) tb=substr(f[i],3)+0
                }
                s += rb+tb; c++
            }
            END { printf "  socket 数 %d, 收发缓冲合计 %.2f MB\n", c, s/1048576 }
        '
        echo
        c_blu "--- 缓冲占用 Top8 的连接 ---"
        ss -tanm 2>/dev/null | awk '
            /^[ \t]*skmem:/ {
                if (cur == "") next
                line=$0; gsub(/[(),]/," ",line); n=split(line,f," ")
                rb=0; tb=0
                for (i=1;i<=n;i++) {
                    if (f[i] ~ /^rb[0-9]+$/) rb=substr(f[i],3)+0
                    if (f[i] ~ /^tb[0-9]+$/) tb=substr(f[i],3)+0
                }
                printf "%8.2f MB  %s\n", (rb+tb)/1048576, cur
                cur=""; next
            }
            /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT|TIME-WAIT|CLOSE-WAIT|LAST-ACK|CLOSING)/ { cur=$0; next }
        ' | sort -rn | head -8
    else
        c_yel "  ss 未安装 (apt install -y iproute2)"
    fi

    echo
    c_blu "════════════════ 五、监听端口上的连接数 ════════════════"
    if command -v ss >/dev/null 2>&1; then
        local ports="" p n
        ports=$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' \
                | grep -E '^[0-9]+$' | sort -un | grep -vxE '22' | head -12)
        if [ -z "$ports" ]; then
            c_yel "  没发现 TCP 监听端口 (服务是不是没起?)"
        else
            printf "  %-8s %-8s %s\n" "端口" "连接数" "备注"
            for p in $ports; do
                n=$(ss -tan 2>/dev/null | awk -v P=":$p" 'NR>1 && ($4 ~ (P "$") || $5 ~ (P "$"))' | wc -l)
                printf "  %-8s %-8s %s\n" "$p" "$n" \
                    "$( [ "$n" -ge 20 ] && echo '每条连接至少 2 个 socket, 偏多了' )"
            done
        fi
    fi

    echo
    c_blu "════════════════ 六、进程占用 Top10 (按 RSS) ════════════════"
    printf "  %9s  %-40s %s\n" "RSS" "进程" "PID"
    proc_top_by_rss | sed 's/^/  /'

    echo
    c_blu "════════════════ 七、OOM 防护是否到位 ════════════════"
    local adj1
    adj1=$(cat /proc/1/oom_score_adj 2>/dev/null)
    if [ -n "$adj1" ] && [ "$adj1" -lt 0 ] 2>/dev/null; then
        c_grn "  PID1 oom_score_adj = ${adj1}  → 内核不会再优先杀 init ✔"
    else
        c_red "  PID1 oom_score_adj = ${adj1:-?}  → init 仍是合法靶子, 一被杀整机就停"
        c_yel "  修: bash $0 protect"
    fi
    if have_systemd; then
        local u cap
        for u in xray tunnel caddy; do
            systemctl cat "${u}.service" >/dev/null 2>&1 || continue
            cap=$(systemctl show -p MemoryMax --value "$u" 2>/dev/null)
            if [ -n "$cap" ] && [ "$cap" != "infinity" ]; then
                c_grn "  ${u}.service MemoryMax=$(h_mb "$cap") 已生效"
            else
                c_yel "  ${u}.service MemoryMax 未设置"
            fi
        done
    else
        c_yel "  没有运行中的 systemd → 服务限额这一层用不了, 只能靠 sysctl + protect。"
    fi

    echo
    c_blu "════════════════ 八、最近一次 OOM 取证 ════════════════"
    local got=""
    if command -v journalctl >/dev/null 2>&1; then
        got=$(journalctl -k --no-pager 2>/dev/null | grep -E 'invoked oom-killer|oom-kill:|Out of memory' | tail -8)
    fi
    [ -z "$got" ] && [ -r /var/log/kern.log ] && \
        got=$(grep -E 'invoked oom-killer|Out of memory' /var/log/kern.log 2>/dev/null | tail -8)
    [ -z "$got" ] && [ -r /var/log/syslog ] && \
        got=$(grep -E 'invoked oom-killer|Out of memory' /var/log/syslog 2>/dev/null | tail -8)
    [ -z "$got" ] && command -v dmesg >/dev/null 2>&1 && \
        got=$(dmesg 2>/dev/null | grep -E 'invoked oom-killer|Out of memory' | tail -8)
    if [ -n "$got" ]; then
        printf '%s\n' "$got"
    else
        c_yel "  取不到 (平台藏了内核日志 / dmesg 受限)。用服务商给的那张图就够了。"
    fi

    echo
    c_blu "════════════════ 九、本脚本改动状态 ════════════════"
    [ -f "$SYSCTL_FILE" ] && c_grn "  已写入 $SYSCTL_FILE"  || c_yel "  未写入 sysctl 调优"
    [ -f "$PROTECT_UNIT" ] && c_grn "  已安装 init OOM 保护" || c_yel "  未安装 init OOM 保护"
    echo
}

# ============================================================================
#  2. 套用 sysctl 调优
# ============================================================================
do_apply() {
    need_root
    profile_values "${1:-2}" || { c_red "档位只能是 1 / 2 / 4"; return 1; }
    mkdir -p "$STATE_DIR" "$SYSCTL_DIR"

    echo
    c_blu "════════ 档位: ${P_NAME} ════════"
    c_yel "  ${P_BDP}"
    echo
    # 先量当前值, 后面的解释才有意义 —— 每台机器的镜像默认值都不一样
    local cur_rmax cur_wmax cur_tsq cur_lowat
    cur_rmax=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    cur_wmax=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    cur_tsq=$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)
    cur_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)

    c_blu "  这台机器的现状 → 改完:"
    printf "    %-28s %-12s → %s\n" "tcp_rmem  max"  "$(h_mb "${cur_rmax:-?}")" "$(h_mb "$P_RMEM_MAX")"
    printf "    %-28s %-12s → %s\n" "tcp_wmem  max"  "$(h_mb "${cur_wmax:-?}")" "$(h_mb "$P_WMEM_MAX")"
    printf "    %-28s %-12s → %s\n" "tcp_limit_output_bytes" "${cur_tsq:-?}" "${P_TSQ}"
    printf "    %-28s %-12s → %s\n" "tcp_notsent_lowat" "${cur_lowat:-?}" "16384"
    echo

    c_yel "  原理: xray 转发一条流占 2 个 socket (上游 recv + 下游 send),"
    if [ -n "$cur_rmax" ] && [ "$cur_rmax" -gt 4194304 ] 2>/dev/null; then
        c_red  "        你这台现在单流接收上限是 $(h_mb "$cur_rmax") —— 远超内核默认的 6MB,"
        c_red  "        是镜像里有人给高 BDP 链路调过的。一条流两个 socket 能吃到 $(( (cur_rmax + cur_wmax) / 1048576 ))MB,"
        c_red  "        并发 5 条就顶穿 256MB —— 这就是 sock 150MB 的来源。"
    else
        c_yel "        默认 6MB/4MB 上限下, 一条流最多压 10MB; 并发 8 条 = 80MB。"
    fi
    c_yel ""
    c_yel "        压小 max 后内核会提前缩窗口, 数据留在对端而不是我们这边。"
    c_yel "        代价是单流峰值下降 (见上面 BDP 换算), 多线程下载可线性补回。"
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

    # 逐条应用而不是 sysctl -p 一把梭: 容器常有 sysctl 白名单,
    # 一条失败不该连累后面的条目。失败项收集起来最后统一报告。
    # 关键区分: net.* 是「按网络命名空间隔离」的, 容器内可写;
    #           vm.* 是「全局」的, 容器内基本一定只读 (读到的是宿主机值)。
    # 所以 vm.* 失败属于预期, 不能算进方案失败。
    local okn=0 k v line
    local ok_net=0 ok_vm=0 bad_net="" bad_vm="" kskip=""
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k=${line%%=*}; k=$(printf '%s' "$k" | tr -d ' \t')
        v=${line#*=}; v=$(printf '%s' "$v" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')
        [ -n "$k" ] && [ -n "$v" ] || continue
        # 值必须是非空数字/空格序列, 否则跳过 (防止残留占位符被写进去)
        case "$v" in *[!0-9[:space:]]*) kskip="$kskip
      $k (值异常: '$v')"; continue ;; esac
        if sysctl -w "${k}=${v}" >/dev/null 2>&1; then
            okn=$((okn + 1))
            case "$k" in net.*) ok_net=$((ok_net + 1)) ;; vm.*) ok_vm=$((ok_vm + 1)) ;; esac
        else
            case "$k" in
                net.*) bad_net="$bad_net
      $k" ;;
                *)     bad_vm="$bad_vm
      $k" ;;
            esac
        fi
    done < "$SYSCTL_FILE"

    echo
    c_blu "--- 应用结果 ---"
    c_grn "  ✔ 网络栈参数 (net.*): 成功 ${ok_net} 项  <- 决定 sock 能不能压住"
    if [ -n "$bad_net" ]; then
        c_red "  ✘ 网络栈参数被拒绝:${bad_net}"
        c_yel "    这些是 network namespace 内的参数, 正常容器都能写。"
        c_yel "    被拒说明平台加了 sysctl 白名单, 需要工单放开, 否则方案会失效。"
    fi
    if [ "$ok_vm" -gt 0 ] || [ -n "$bad_vm" ]; then
        if [ -n "$bad_vm" ]; then
            c_yel "  ⚠ 内核/VM 参数 (vm.*): 写了 ${ok_vm} 项, 被拒若干 -- 属预期。"
            c_yel "    vm.* 是全局参数、不分容器, 容器内基本一定只读。"
            c_yel "    这块在裸机上才有意义; 你看到的 min_free_kbytes 是宿主机的, 别管它。"
        else
            c_grn "  ✔ 内核/VM 参数 (vm.*): 成功 ${ok_vm} 项 (难得, 说明没被限制)"
        fi
    fi
    if [ -n "$kskip" ]; then
        c_yel "  ⚠ 跳过 (值异常) :${kskip}"
    fi

    echo
    c_blu "--- 核心项验证 ---"
    local v_r v_w v_s v_l fail_core=0
    v_r=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    v_w=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
    v_s=$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)
    v_l=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    printf "  %-28s = %s\n" "tcp_rmem"             "${v_r:-读不到}"
    printf "  %-28s = %s\n" "tcp_wmem"             "${v_w:-读不到}"
    printf "  %-28s = %s\n" "tcp_limit_output_bytes" "${v_s:-读不到}"
    printf "  %-28s = %s\n" "tcp_notsent_lowat"    "${v_l:-读不到}"
    [ "$(printf '%s' "$v_r" | awk '{print $3}')" = "$P_RMEM_MAX" ] || fail_core=1
    [ "$(printf '%s' "$v_w" | awk '{print $3}')" = "$P_WMEM_MAX" ] || fail_core=1

    echo
    if [ "$fail_core" -eq 1 ]; then
        c_red "  ✘ 核心项没生效 —— 这台机器把 net.ipv4.tcp_rmem 设成了只读。"
        c_yel "    在这种托管容器里, 内核缓冲参数改不了, 本脚本的第三道防线失效。"
        c_yel "    那就只剩 protect + limits + 客户端限线程 + 关 argo 这几条了。"
        echo
        return 1
    fi
    c_grn "  ✔ 核心项已生效。不需要重启服务, 新连接立即使用新上限。"
    c_yel "    已有连接沿用旧缓冲大小, 断开重连后才切换 —— 这也是要重启服务的原因之一。"
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
#  3.5 cgroup memory.high —— sysctl 被锁死时的第二条路
#
#  memory.max 是硬限, 撞上直接 OOM 杀进程。
#  memory.high 是软限, 越过它内核会「先回收再说」: 压 page cache、
#  回收可回收页、并把该 cgroup 里的进程按配额限速 (return-to-user 节流),
#  而不是立刻开枪。对小内存机器这就是「撞墙前的刹车」。
#
#  为什么这条特别值得开: net.ipv4.* 被平台锁读时 (b4 里那种托管容器),
#  sysctl 那条主防线直接失效, 而 cgroup 自己的文件通常还能写。
# ============================================================================
do_cgroup() {
    need_root
    local root="${CGROUP_ROOT:-/sys/fs/cgroup}"
    echo
    c_blu "════════ 设置 cgroup 软限 memory.high ════════"

    if [ ! -f "$root/memory.max" ]; then
        c_red "  没有 cgroup v2 接口 ($root/memory.max 不存在)。"
        c_yel "  宿主机是 cgroup v1 或被完全屏蔽, 这一层用不了。"
        echo
        return 1
    fi

    local mx cur hi
    mx=$(cat "$root/memory.max" 2>/dev/null)
    cur=$(cat "$root/memory.current" 2>/dev/null)
    hi=$(cat "$root/memory.high" 2>/dev/null)
    c_blu "  现状:"
    printf "    %-14s %s\n" "memory.max"     "$( [ "$mx" = max ] && echo 'max (没有硬限!)' || h_mb "$mx" )"
    printf "    %-14s %s\n" "memory.current" "$(h_mb "$cur")"
    printf "    %-14s %s\n" "memory.high"    "$( [ "$hi" = max ] && echo 'max (等于没设软限)' || h_mb "$hi" )"
    echo

    if [ "$mx" = "max" ]; then
        c_yel "  memory.max 是 max, 说明这个 cgroup 本身没有硬限 ——"
        c_yel "  你看到的 256MB 限制来自上一层, 这里设 high 意义不大, 跳过。"
        echo
        return 1
    fi

    # 留 12% 余量: 到线就开始刹车, 不要等撞上硬限
    local target
    target=$(( mx / 100 * 88 ))
    c_yel "  目标 memory.high = ${mx} 的 88% = $(h_mb "$target")"
    c_yel "  含义: 涨到这一线开始回收/节流, 而不是直接 OOM 停机。"
    c_yel "        硬限仍是 $(h_mb "$mx"), 只是提前有缓冲带。"
    echo

    if ! printf '%s' "$target" > "$root/memory.high" 2>/dev/null; then
        c_red "  ✘ 写不进去。cgroup 内存控制器没委托给容器, 这层用不了。"
        c_yel "    检查: ls -l $root/memory.high   (看属主能不能写)"
        echo
        return 1
    fi
    c_grn "  ✔ memory.high 已设为 $(h_mb "$(cat "$root/memory.high" 2>/dev/null)")"

    # 容器重启后 high 会回到 max, 用 oneshot 单元在早期重新写一次
    mkdir -p "$STATE_DIR"
    if have_systemd && [ -n "$DROPIN_DIR" ]; then
        local unit="${DROPIN_DIR}/xray-mem-high.service"
        cat > "$unit" <<EOF
# 由 xray-mem-fix.sh 生成 — 容器重启后把 cgroup 软限重新设上
# 删除: rm ${unit} && systemctl daemon-reload
[Unit]
Description=Set cgroup memory.high (xray-mem-fix)
DefaultDependencies=no
After=sysinit.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'printf ${target} > ${root}/memory.high 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
        record_created "$unit"
        if systemctl daemon-reload 2>/dev/null && \
           systemctl enable --now xray-mem-high.service >/dev/null 2>&1; then
            c_grn "  ✔ 已装开机自启单元 xray-mem-high.service"
        else
            c_yel "  ⚠ 自启单元没启用成功, 当前已生效, 重启容器后需重跑一次 cgroup"
        fi
    else
        c_yel "  没有运行中的 systemd, 重启容器后需重跑一次 cgroup"
    fi

    echo
    c_yel "  注意: memory.high 对 sock (内核内存) 不能直接回收,"
    c_yel "        它的价值是提前节流进程、压掉 page cache, 给 sock 腾地方。"
    c_yel "        配合 apply 的缓冲上限才完整 —— 单靠它治不了根。"
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
#  6.5 前台采样: 抓 OOM 那一刻到底是谁在涨 (只读)
# ============================================================================
do_watch() {
    local interval="${1:-5}"
    case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
    [ "$interval" -lt 1 ] && interval=1

    local statf=/sys/fs/cgroup/memory.stat
    [ -r "$statf" ] || statf=/sys/fs/cgroup/memory/memory.stat
    local curf=/sys/fs/cgroup/memory.current
    [ -r "$curf" ] || curf=/sys/fs/cgroup/memory/memory.usage_in_bytes
    if [ ! -r "$curf" ]; then
        c_red "读不到 cgroup 内存文件, 换台机器或去掉容器层再试。"
        return 1
    fi

    mkdir -p "$STATE_DIR"
    local log="${STATE_DIR}/peak.log"
    local maxb peak_sock peak_conn peak_t
    maxb=0; peak_sock=0; peak_conn=0; peak_t=""

    echo
    c_blu "════════ 采样中 (每 ${interval}s, Ctrl-C 结束) ════════"
    c_yel "  对应你截图那张表: sock 是内核缓冲, anon 是进程实际占用。"
    c_yel "  sock 涨到 100MB 以上就是正在往 OOM 走的信号。"
    printf "  %-19s %10s %10s %8s
" "时间" "总计" "sock" "连接数"
    echo "  ────────────────────────────────────────────────"

    trap 'echo; printf "  峰值: 总 %s / sock %s / 连接 %s (发生在 %s)\n" \
        "$(h_mb "$maxb")" "$(h_mb "$peak_sock")" "$peak_conn" "${peak_t:-n/a}"
        printf "  采样日志: %s\n" "$log"; return 0' INT

    local cur sock conn n
    while :; do
        cur=$(cat "$curf" 2>/dev/null); cur=${cur:-0}
        sock=$(awk '$1=="sock"{print $2}' "$statf" 2>/dev/null); sock=${sock:-0}
        conn=$(ss -tan 2>/dev/null | awk 'NR>1 && $1=="ESTAB"' | wc -l)
        n=$(date '+%H:%M:%S')
        printf "  %-19s %10s %10s %8s\n" "$n" "$(h_mb "$cur")" "$(h_mb "$sock")" "$conn"
        if [ "$cur" -gt "$maxb" ] 2>/dev/null; then maxb=$cur; peak_t=$n; fi
        if [ "$sock" -gt "$peak_sock" ] 2>/dev/null; then peak_sock=$sock; fi
        if [ "$conn" -gt "$peak_conn" ] 2>/dev/null; then peak_conn=$conn; fi
        printf '%s cur=%s sock=%s conn=%s\n' "$n" "$cur" "$sock" "$conn" >> "$log"
        sleep "$interval"
    done
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
    do_apply "${1:-2}" || c_yel "
  (apply 报了问题, 继续跑后面两道防线)"
    do_protect
    do_cgroup
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
        c_grn "  7b.只设 cgroup 软限 memory.high (sysctl 被锁时用)"
        echo "  ─────────────────────────────"
        c_grn "  8. 添加 512MB swap"
        c_grn "  9. 看配置减肥建议 (关 argo / 关 sniffing)"
        echo "  ─────────────────────────────"
        c_grn " 10. 前台采样 (抓 OOM 前的 sock 曲线)"
        c_red " 11. 还原全部改动"
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
            7b) do_cgroup;  pause ;;
            8)  do_swap;    pause ;;
            9)  do_advice;  pause ;;
            10) do_watch;   pause ;;
            11) do_revert;  pause ;;
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
        cgroup)    do_cgroup ;;
        swap)      do_swap ;;
        advice)    do_advice ;;
        watch)     do_watch "${2:-5}" ;;
        revert)    do_revert ;;
        all)       do_all "${2:-2}" ;;
        "")        menu ;;
        -h|--help|help)
            sed -n '2,24p' "$0" ;;
        *)  c_red "未知操作: ${action}"
            echo "用法: bash $0 [status|apply [1|2|4]|protect|limits|cgroup|swap|advice|watch [秒]|revert|all]"
            exit 1 ;;
    esac
}

main "$@"
