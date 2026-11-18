#!/usr/bin/env bash
# ============================================================================
#  bw-diag.sh — 低配 NAT 小鸡：到底是「平台限速」还是「CPU/配置不够」
#
#  用法:
#     bash bw-diag.sh                  # 全套体检 + 测速 + 结论 (约 40 秒)
#     bash bw-diag.sh info             # 只看机器参数 (不耗流量)
#     bash bw-diag.sh cpu              # CPU 加密跑分 (不耗流量)
#     bash bw-diag.sh raw [流数] [秒]  # 纯 HTTP 测速 (不经代理、无 TLS)
#     bash bw-diag.sh tls [流数] [秒]  # HTTPS 测速 (带 TLS，近似代理的加密开销)
#     bash bw-diag.sh verdict          # 只说结论 (读上一次的结果)
#     bash bw-diag.sh deps             # 检查依赖工具是否齐全
#
#  环境变量:
#     CLAIM=200   服务商标称带宽 (Mbps)，默认 200
#     DUR=5       每次测速的秒数，默认 5 (流量紧就设 2)
#
#  核心判据 —— 三个数字就能定性:
#     ① 纯 HTTP 多流总和  ≈ 标称  → 管子没问题，瓶颈在 CPU 或代理配置
#     ② 纯 HTTP 多流总和 << 标称  → 管子本身被限速，跟 CPU 无关
#     ③ HTTP 快、HTTPS 慢而 CPU 满 → 加密在吃 CPU，是配置不够
#
#  为什么要分开测 HTTP 和 HTTPS:
#     纯 HTTP 不加密，CPU 几乎不参与 → 测出来的是「管道能拉多少」
#     HTTPS 要加解密，CPU 参与     → 测出来的是「CPU 能加多少密」
#     代理真实速度 ≈ min(管道, CPU)。哪个更低，哪个就是瓶颈。
# ============================================================================
set -uo pipefail
# 本机自测时 msys 的默认 PATH 里没有 /usr/bin (awk/grep/sed 全找不到);
# 线上 alpine/debian 自带这些, 这个判断不会触发。
if ! command -v awk >/dev/null 2>&1; then
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
fi

RED=$'\033[1;91m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
BLU=$'\033[1;36m'; DIM=$'\033[2m';    R=$'\033[0m'
c_red(){ printf '%s\n' "${RED}$*${R}"; }
c_grn(){ printf '%s\n' "${GRN}$*${R}"; }
c_yel(){ printf '%s\n' "${YEL}$*${R}"; }
c_blu(){ printf '%s\n' "${BLU}$*${R}"; }
c_dim(){ printf '%s\n' "${DIM}$*${R}"; }

SELF="${BASH_SOURCE[0]:-$0}"
case "$SELF" in /dev/fd/*|/proc/*|-) SELF="bw-diag.sh" ;; esac

CLAIM="${CLAIM:-200}"
DUR="${DUR:-5}"
STATE="${TMPDIR:-/tmp}/bw-diag-last"
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)

TMPD=""
cleanup(){ [ -n "$TMPD" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM
mktmp(){ TMPD=$(mktemp -d 2>/dev/null) || TMPD="/tmp/bw-diag.$$"; mkdir -p "$TMPD" 2>/dev/null; }

# ---------------------------------------------------------------- 基础工具
now_ms(){
    local t
    t=$(date +%s%N 2>/dev/null)
    case "$t" in
        ""|*[!0-9]*) ;;
        *) printf '%s' "$(( t / 1000000 ))"; return 0 ;;
    esac
    t=$(date +%s%3N 2>/dev/null)
    case "$t" in
        ""|*[!0-9]*) ;;
        *) printf '%s' "$t"; return 0 ;;
    esac
    printf '%s' "$(( $(date +%s) * 1000 ))"
}

state_put(){ [ -n "${STATE:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$STATE" 2>/dev/null; }
state_get(){
    [ -f "$STATE" ] || { printf ''; return; }
    grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-
}

# /proc/stat 的 cpu 行: 总时间与空闲时间(含 iowait)
cpu_stat(){ awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat 2>/dev/null; }

cpu_busy(){
    awk -v a="${1:-0 0}" -v b="${2:-0 0}" 'BEGIN{
        split(a,x," "); split(b,y," ")
        dt=y[1]-x[1]; di=y[2]-x[2]
        if (dt<=0) { print "0.0"; exit }
        printf "%.1f", (dt-di)*100/dt
    }'
}

# /proc/PID/stat 里 comm 可能带空格, 必须从最后一个 ") " 之后开始数
proc_cpu_ticks(){
    local line rest
    line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest=${line##*\) }
    printf '%s' "$rest" | awk '{print $12+$13}'
}

# 找代理类进程 (xray / sing-box / argo / cloudflared / hysteria / tuic)
proxy_pids(){
    local d pid nm
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        pid=${d#/proc/}
        nm=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$nm" in
            *xray*|*sing-box*|*argo*|*cloudflared*|*hysteria*|*tuic*) printf '%s\n' "$pid" ;;
        esac
    done
}

proxy_ticks_sum(){
    local p t sum=0
    for p in $(proxy_pids); do
        t=$(proc_cpu_ticks "$p" 2>/dev/null) || continue
        sum=$(( sum + ${t:-0} ))
    done
    printf '%s' "$sum"
}

have(){ command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 下载测速
# busybox wget / GNU wget 都认 --no-check-certificate, 但老版本可能不认;
# 拿不到数据时退回不带该参数再试一次 (测速点是公开的, 证书本身没问题)。
dl_bytes(){
    local url=$1 dur=$2 n
    n=$( { timeout "$dur" wget -q --no-check-certificate -O - "$url" 2>/dev/null; } | wc -c )
    n=${n:-0}
    if [ "$n" -eq 0 ]; then
        n=$( { timeout "$dur" wget -q -O - "$url" 2>/dev/null; } | wc -c )
        n=${n:-0}
    fi
    printf '%s' "$n"
}

dl_multi(){
    local url=$1 dur=$2 n=$3 i=0 f tot=0
    local pids=""
    while [ "$i" -lt "$n" ]; do
        i=$((i + 1))
        ( dl_bytes "$url" "$dur" > "$TMPD/s$i" ) &
        pids="$pids $!"
    done
    for f in $pids; do wait "$f" 2>/dev/null; done
    for f in "$TMPD"/s*; do
        [ -f "$f" ] && tot=$(( tot + $(cat "$f" 2>/dev/null || echo 0) ))
    done
    printf '%s' "$tot"
}

probe_url(){ printf '%s' "$(dl_bytes "$1" 3)"; }

HTTP_URLS="
http://cachefly.cachefly.net/100mb.test
http://proof.ovh.net/files/100Mb.dat
http://speedtest.tele2.net/100MB.zip
http://ipv4.download.thinkbroadband.com/100MB.zip
"
TLS_URLS="
https://speed.cloudflare.com/__down?bytes=104857600
https://proof.ovh.net/files/100Mb.dat
https://cachefly.cachefly.net/100mb.test
"

pick_url(){
    local scheme=$1 list u n best_u="" best_n=0
    case "$scheme" in http) list="$HTTP_URLS" ;; *) list="$TLS_URLS" ;; esac
    c_dim "  探测 $scheme 测速点..."
    for u in $list; do
        n=$(probe_url "$u")
        if [ "${n:-0}" -gt "$best_n" ]; then best_n=$n; best_u=$u; fi
        c_dim "    $(printf '%-58s' "$u") 3 秒拿到 $(( n / 1024 )) KB"
    done
    if [ "$best_n" -eq 0 ]; then
        c_red "  ✘ 所有 $scheme 测速点都拿不到数据 (网络不通或被墙)"
        return 1
    fi
    state_put "url_$scheme" "$best_u"
    c_grn "  ✔ 用 $(printf '%s' "$best_u")"
    return 0
}

# run_case <scheme> <流数> <秒> <结果键>
run_case(){
    local scheme=$1 streams=$2 dur=$3 key=$4
    local url; url=$(state_get "url_$scheme")
    [ -n "$url" ] || { c_yel "  跳过: 没有 $scheme 测速点"; return 1; }

    local a b pt0 pt1 t0 t1 bytes ms mbs sys_pct pr_pct
    a=$(cpu_stat); pt0=$(proxy_ticks_sum); t0=$(now_ms)
    bytes=$(dl_multi "$url" "$dur" "$streams")
    t1=$(now_ms); b=$(cpu_stat); pt1=$(proxy_ticks_sum)

    ms=$(( t1 - t0 )); [ "$ms" -le 0 ] && ms=1000
    mbs=$(awk -v b="$bytes" -v m="$ms" 'BEGIN{printf "%.2f", (b/1048576)/(m/1000)}')
    sys_pct=$(cpu_busy "$a" "$b")
    pr_pct=$(awk -v d="$(( pt1 - pt0 ))" -v h="$HZ" -v s="$ms" \
        'BEGIN{ if (s<=0) {print "0.0"; exit}; printf "%.1f", d*100*1000/(h*s) }')

    state_put "$key" "$mbs"
    state_put "${key}_sys" "$sys_pct"
    state_put "${key}_proxy" "$pr_pct"
    state_put "${key}_mb" "$(awk -v b="$bytes" 'BEGIN{printf "%.0f", b/1048576}')"

    printf '  %-22s %7s MB/s   (系统 CPU %5s%%  代理进程 %5s%%  用量 %s MB)\n' \
        "$scheme/${streams}流" "$mbs" "$sys_pct" "$pr_pct" \
        "$(state_get "${key}_mb")"
}

# ---------------------------------------------------------------- 子命令
do_info(){
    echo
    c_blu "════════ 一、机器配置 ════════"
    local cores model mhz mhzmax mem_kb kern load nic spd
    cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    model=$(awk -F: '/^model name|^cpu model|^Hardware/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    [ -z "$model" ] && model=$(awk -F: '/^Model/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    mhz=$(awk -F: '/^cpu MHz/{gsub(/^ +/,"",$2); print int($2); exit}' /proc/cpuinfo 2>/dev/null)
    [ -z "$mhz" ] && mhz=$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    mhzmax=$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    mem_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    kern=$(uname -r 2>/dev/null)
    load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)

    printf '  %-12s %s\n' "CPU 核心" "${cores:-?}"
    printf '  %-12s %s\n' "CPU 型号" "${model:-读不到(虚拟化常隐藏)}"
    printf '  %-12s %s\n' "频率" "${mhz:-?} MHz${mhzmax:+ (最高 ${mhzmax})}"
    printf '  %-12s %s\n' "内存" "$(awk -v k="${mem_kb:-0}" 'BEGIN{printf "%.0f MB", k/1024}')"
    printf '  %-12s %s\n' "内核" "${kern:-?}"
    printf '  %-12s %s\n' "负载" "${load:-?}"

    echo
    c_blu "════════ 二、网卡与限速规则 ════════"
    for nic in /sys/class/net/*; do
        [ -d "$nic" ] || continue
        local n; n=$(basename "$nic")
        [ "$n" = "lo" ] && continue
        spd=$(cat "$nic/speed" 2>/dev/null)
        printf '  %-12s 状态 %-7s 速率 %s\n' "$n" \
            "$(cat "$nic/operstate" 2>/dev/null || echo '?')" "${spd:+${spd} Mb/s}${spd:-读不到}"
    done
    c_dim "  注: 虚拟网卡报的速率多为假值(常是 10000)，只能参考，不能当带宽依据。"

    if have tc; then
        local q; q=$(tc qdisc show 2>/dev/null)
        if printf '%s' "$q" | grep -qE 'tbf|htb|fq_codel.*limit|netem'; then
            c_yel "  发现本机 egress 限速规则:"
            printf '%s\n' "$q" | sed 's/^/    /'
        else
            c_dim "  本机没有 egress 限速规则 (tc qdisc 只有默认队列) → 限速不在容器里。"
        fi
    fi

    echo
    c_blu "════════ 三、当前 TCP 参数 ════════"
    printf '  %-26s %s\n' "tcp_congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  %-26s %s\n' "tcp_rmem"  "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
    printf '  %-26s %s\n' "tcp_wmem"  "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    printf '  %-26s %s\n' "tcp_mtu_probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
    local rmax; rmax=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    if [ -n "$rmax" ] && [ "$rmax" -lt 262144 ] 2>/dev/null; then
        c_yel "  ↑ tcp_rmem 上限很小，单流会被窗口卡住。多流能叠加就没关系。"
    fi
    echo
}

# OpenSSL 的 `speed` 把 "Doing ... ops" 逐行输出到 stderr, 汇总表输出到 stdout:
#   type             16 bytes     64 bytes   ...   16384 bytes
#   AES-128-GCM     214880.14k   381942.09k  ...   476184.58k
# 表里单位是 "1000s of bytes per second", 即 v(k) = v*1000 B/s。
# 各列会随运行时长抖动(短跑时 16KB 列常常反而低), 取所有列的最大值最稳。
ssl_speed_mbs(){
    local algo=$1 pat
    case "$algo" in
        aes*) pat='^[Aa][Ee][Ss]-128-[Gg][Cc][Mm]' ;;
        *)    pat='^[Cc]h[Aa][Cc][Hh][Aa]20-' ;;
    esac
    openssl speed -evp "$algo" -seconds 2 2>/dev/null | awk -v pat="$pat" '
        $0 ~ pat {
            best = 0
            for (i = 2; i <= NF; i++) {
                v = $i
                sub(/k$/, "", v)
                v = v + 0
                if (v > best) best = v
            }
            if (best > 0) printf "%.1f", best * 1000 / 1048576
        }
    '
}

do_cpu(){
    echo
    c_blu "════════ CPU 加密能力 ════════"
    if ! have openssl; then
        c_yel "  没装 openssl，跳过。alpine: apk add openssl / debian: apt install openssl"
        return 1
    fi
    local cores; cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [ -z "$cores" ] || [ "$cores" -lt 1 ] && cores=1
    c_dim "  跑 2 秒 AES-128-GCM 与 ChaCha20-Poly1305 (TLS 最常用的两种)，取 16KB 块的吞吐"
    echo

    local aes cha
    aes=$(ssl_speed_mbs aes-128-gcm)
    cha=$(ssl_speed_mbs chacha20-poly1305)

    printf '  %-24s %s MB/s (单核)\n' "AES-128-GCM"      "${aes:-0.0}"
    printf '  %-24s %s MB/s (单核)\n' "ChaCha20-Poly1305" "${cha:-0.0}"
    echo

    local best
    best=$(awk -v a="${aes:-0}" -v c="${cha:-0}" 'BEGIN{ printf "%.1f", (a > c) ? a : c }')
    if awk -v b="$best" 'BEGIN{ exit !(b > 0) }'; then
        state_put "crypto_mbs" "$best"
        state_put "cores" "${cores:-1}"

        c_blu "  换算: 不同下载速度下，光加解密这一项就吃掉多少单核"
        for t in 3 5 10 17 25 50; do
            awk -v b="$best" -v t="$t" 'BEGIN{
                p = t / b * 100
                mark = ""
                if (p >= 80) mark = "   <- 单核基本占满"
                else if (p >= 50) mark = "   <- 吃掉一半以上"
                printf "    %5.1f MB/s 下载  ->  加解密占单核 %5.1f%%%s\n", t, p, mark
            }'
        done
        echo

        # 单核能加密多少 MB/s, 就是这个核在纯 TLS 转发下的天花板
        c_blu "  这台机器纯 TLS 转发的算力天花板:"
        awk -v b="$best" -v n="$cores" 'BEGIN{
            printf "    单核 %.1f MB/s, 共 %d 核 -> 理论 %.1f MB/s (还没算转发本身的开销)\n", b, n, b*n
        }'
        echo
        if awk -v b="$best" -v n="$cores" 'BEGIN{ exit !(b*n < 25) }'; then
            c_red "  ↑ 算力不够。标称 200Mbps(=25MB/s) 就算管道给满, 它也加密不过来。"
            c_yel "     想跑满只能换 CPU 更强的机器, 或者用不加密/轻加密的协议。"
        elif awk -v b="$best" -v n="$cores" 'BEGIN{ exit !(b*n < 60) }'; then
            c_yel "  ↑ 算力勉强。跑 25MB/s 时单核会吃掉 60%-90%, 其他活就抢不到 CPU 了。"
        else
            c_grn "  ↑ 算力够。200Mbps 的加解密只占单核的一小部分。"
        fi
    else
        c_yel "  openssl speed 没跑出结果 (可能被禁用或版本太老)，跳过。"
    fi
    echo
}

do_speed(){
    local mode=$1 streams=${2:-8} dur=${3:-$DUR}
    mktmp
    [ -f "$STATE" ] && : > "$STATE"

    echo
    c_blu "════════ 测速 (每次 ${dur}s × ${streams} 流) ════════"
    c_dim "  预计消耗流量: 约 $(( DUR * 25 * 4 )) MB (按 25MB/s 估)。流量紧就用 DUR=2 跑。"
    echo

    pick_url http || true
    pick_url tls  || true
    echo

    c_blu "  --- 纯 HTTP (不加密，测管道) ---"
    [ -n "$(state_get url_http)" ] && {
        run_case http 1 "$dur" raw_single || true
        run_case http "$streams" "$dur" raw_multi || true
    }

    echo
    c_blu "  --- HTTPS (带 TLS，测 CPU 加密) ---"
    [ -n "$(state_get url_tls)" ] && {
        run_case tls 1 "$dur" tls_single || true
        run_case tls "$streams" "$dur" tls_multi || true
    }
    echo
}

do_verdict(){
    local claim_mbs raw1 raw8 tls1 tls8 sys8 pr8 crypto cores
    claim_mbs=$(awk -v c="$CLAIM" 'BEGIN{printf "%.1f", c/8}')
    raw1=$(state_get raw_single); raw8=$(state_get raw_multi)
    tls1=$(state_get tls_single); tls8=$(state_get tls_multi)
    sys8=$(state_get raw_multi_sys); pr8=$(state_get raw_multi_proxy)
    crypto=$(state_get crypto_mbs); cores=$(state_get cores)

    [ -n "$raw8" ] || [ -n "$raw1" ] || { c_red "  没有测速数据，先跑 bash $SELF raw"; return 1; }

    echo
    c_blu "════════ 结论 ════════"
    printf '  标称带宽      %s Mbps = %s MB/s\n' "$CLAIM" "$claim_mbs"
    [ -n "$raw1" ] && printf '  纯HTTP 1 流   %s MB/s\n' "$raw1"
    [ -n "$raw8" ] && printf '  纯HTTP 多流   %s MB/s   (系统CPU %s%%)\n' "$raw8" "${sys8:-?}"
    [ -n "$tls1" ] && printf '  HTTPS 1 流    %s MB/s\n' "$tls1"
    [ -n "$tls8" ] && printf '  HTTPS 多流    %s MB/s\n' "$tls8"
    [ -n "$crypto" ] && printf '  加密上限      %s MB/s 单核 (共 %s 核)\n' "$crypto" "${cores:-1}"
    echo

    # 取两者里更大的当「管道能力」: 单流跑不满可能是窗口小，多流能叠加就说明管子够
    local pipe
    pipe=$(awk -v a="${raw1:-0}" -v b="${raw8:-0}" 'BEGIN{ printf "%.2f", (a>b)?a:b }')

    local pipe_ok=0 pipe_low=0
    awk -v p="$pipe" -v c="$claim_mbs" 'BEGIN{exit !(p >= c*0.70)}' && pipe_ok=1
    awk -v p="$pipe" -v c="$claim_mbs" 'BEGIN{exit !(p <= c*0.35)}' && pipe_low=1

    if [ "$pipe_ok" -eq 1 ]; then
        c_grn "① 管道没问题：纯 HTTP 多流能跑到标称的 70% 以上。"
        c_yel "   → 瓶颈不在服务商限速，在你的 CPU 或代理配置。"
    elif [ "$pipe_low" -eq 1 ]; then
        c_red "① 管道被限速：纯 HTTP 多流也只有标称的 35% 以下。"
        c_yel "   → 不是你的配置问题，加线程也不会更快。找服务商问。"
    else
        c_yel "① 中间地带：纯 HTTP 多流到标称的 35%-70%。"
        c_yel "   → 可能是共享带宽被别人占用，换个时间段再测一次。"
    fi
    echo

    # 单流 vs 多流 → 判断是不是「每连接限速」或「窗口太小」
    if [ -n "$raw1" ] && [ -n "$raw8" ]; then
        awk -v a="$raw1" -v b="$raw8" 'BEGIN{
            ratio=(a>0)?b/a:0
            if (ratio >= 2.5)      print "   单流慢、多流能叠加 -> 不是总量限速，是单连接被限或 TCP 窗口小。"
            else if (ratio <= 1.3) print "   单流和多流差不多 -> 这是总量限制(平台限速或 CPU 打满)。"
            else                   print "   多流略有提升 -> 部分叠加，介于两者之间。"
        }'
    fi
    echo

    if [ -n "$tls8" ] && [ -n "$raw8" ]; then
        awk -v r="$raw8" -v t="$tls8" -v s="${sys8:-0}" 'BEGIN{
            if (t < r*0.6 && s >= 70)
                printf "② CPU 是瓶颈：同样的管子，不加密能跑 %.1f，加密后掉到 %.1f。\n   → 加解密吃满了 CPU。\n", r, t
            else if (t < r*0.6)
                printf "② 加密后明显变慢，但 CPU 没满(%.0f%%)。\n   → 可能是单连接 RTT/窗口问题，不是算力问题。\n", s
            else
                printf "② HTTPS 和 HTTP 差不多 -> 加解密不是瓶颈。\n"
        }'
    fi

    if [ -n "$crypto" ]; then
        awk -v c="$crypto" -v p="${tls8:-0}" 'BEGIN{
            if (p>0 && c>0) {
                printf "③ 加密上限 %.1f MB/s，实测 HTTPS 用掉约 %.0f%% 的单核。\n", c, p/c*100
            }
        }'
    fi
    echo

    local frac
    frac=$(awk -v p="$pipe" -v c="$claim_mbs" 'BEGIN{ if (c>0) printf "%.0f", p/c*100; else print 0 }')
    c_blu "一句话:"
    if [ "$pipe_ok" -eq 1 ]; then
        c_yel "  管子里有 ${pipe} MB/s (标称的 ${frac}%)，你能拿到的比这少，差在 CPU 和代理配置上。"
    elif [ "$pipe_low" -eq 1 ]; then
        c_red "  管子本身就只到 ${pipe} MB/s (标称的 ${frac}%)，这是平台限速，不是你配置不够。"
    else
        c_yel "  管子到 ${pipe} MB/s (标称的 ${frac}%)，不排除共享带宽。多测几次取最高。"
    fi
    echo
    local tot=0 k
    for k in raw_single_mb raw_multi_mb tls_single_mb tls_multi_mb; do
        tot=$(( tot + $(state_get "$k" || echo 0) ))
    done
    c_dim "  本次共消耗流量约 ${tot} MB。"
    echo
}

do_watch(){
    local dur=${1:-30} i=0
    echo
    c_blu "════════ 前台采样 ${dur}s (Ctrl-C 停) ════════"
    printf '  %-10s %-8s %-28s %s\n' "时间" "CPU%" "内存" "代理进程CPU%"
    while [ "$i" -lt "$dur" ]; do
        local a b pm t
        a=$(cpu_stat); pm=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
        t=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
        sleep 2
        b=$(cpu_stat)
        local cp; cp=$(cpu_busy "$a" "$b")
        printf '  %-10s %-8s %-28s %s\n' "$(date +%H:%M:%S)" "$cp" \
            "$(( (${t:-0} - ${pm:-0}) / 1024 )) MB / $(( ${t:-0} / 1024 )) MB" \
            "$(proxy_ticks_sum)"
        i=$((i + 2))
    done
    echo
}

do_deps(){
    echo
    c_blu "════════ 依赖检查 ════════"
    local miss="" t
    for t in awk grep sed wc cut tr sort head cat date mktemp; do
        if have "$t"; then printf '  %-12s ok\n' "$t"
        else printf '  %-12s %s\n' "$t" "缺失"; miss="$miss $t"; fi
    done
    for t in wget timeout openssl sysctl ss tc; do
        if have "$t"; then printf '  %-12s ok\n' "$t"
        else printf '  %-12s %s\n' "$t" "缺失 (相关功能会被跳过)"; fi
    done
    echo
    if [ -n "$miss" ]; then
        c_red "  缺核心工具:$miss"
        c_dim "  alpine: apk add coreutils"
        return 1
    fi
    c_grn "  核心工具齐全。"
    echo
}

need_wget(){
    if ! have wget; then
        c_red "  没有 wget。apk add wget 或用 curl 手动测。"
        return 1
    fi
    if ! have timeout; then
        c_yel "  没有 timeout 命令，测速会一直跑到文件下完。装 coreutils 或忽略。"
    fi
    return 0
}

main(){
    local action="${1:-all}"
    case "$action" in
        info)    do_info ;;
        cpu)     do_cpu ;;
        raw)     need_wget && { mktmp; : > "$STATE"; pick_url http && {
                     echo; run_case http "${2:-1}" "${3:-$DUR}" raw_single
                     echo; run_case http "${2:-8}" "${3:-$DUR}" raw_multi; echo; } ; } ;;
        tls)     need_wget && { mktmp; : > "$STATE"; pick_url tls && {
                     echo; run_case tls "${2:-1}" "${3:-$DUR}" tls_single
                     echo; run_case tls "${2:-8}" "${3:-$DUR}" tls_multi; echo; } ; } ;;
        speed)   need_wget && do_speed raw ;;
        watch)   do_watch "${2:-30}" ;;
        deps)    do_deps ;;
        verdict) do_verdict ;;
        all)
            do_info
            do_cpu
            need_wget && { do_speed all; do_verdict; }
            ;;
        -h|--help|help)
            awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$SELF" 2>/dev/null || \
                sed -n '2,30p' "$SELF"
            ;;
        *)
            c_red "未知操作: ${action}"
            printf '用法: bash %s [info|cpu|raw [流数] [秒]|tls [流数] [秒]|watch [秒]|verdict|deps|all]\n' "$SELF"
            exit 1
            ;;
    esac
}

main "$@"
