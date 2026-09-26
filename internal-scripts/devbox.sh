#!/bin/sh
# devbox 容器内管理工具
# 容器无 systemd: pi-web 与 easytier-core 以 nohup 后台常驻, 由本工具启停; pi 为前台交互进程, 可能同时存在多个, 提供一键清理
set -eu

PI_WEB_LOG="/root/.pi-web.log"
PI_WEB_PORT="${PI_WEB_PORT:-10001}"

# easytier 运行数据固定放 /root 下跟随 bind 持久化, 容器重建不丢配置与日志
# 配置文件由使用者自行编写, 镜像不预置, 避免网络密钥进入镜像层
ET_HOME="/root/easytier"
ET_CONFIG="${ET_HOME}/config/config.toml"
ET_PID_FILE="${ET_HOME}/run/easytier-core.pid"
ET_LOG="${ET_HOME}/logs/easytier-core.log"
# 控制台日志级别, 排查连接问题时改成 warn 或 info
ET_LOG_LEVEL="error"
# 日志轮转: 容器里既没有 cron 也没有 logrotate, 只在 start 前按大小检查一次, 运行期间不轮转,
# 因此单个文件最大是 ET_LOG_MAX_SIZE 再加上一次运行新增的量
ET_LOG_MAX_SIZE=$((5 * 1024 * 1024))
ET_LOG_ARCHIVE_COUNT=3

# 解析实际二进制路径, pgrep 按完整命令行匹配, 避免按进程名误杀无关程序
PI_BIN="$(command -v pi 2>/dev/null || true)"
PI_WEB_BIN="$(command -v pi-web 2>/dev/null || true)"
ET_BIN="$(command -v easytier-core 2>/dev/null || true)"
ET_CLI_BIN="$(command -v easytier-cli 2>/dev/null || true)"

usage() {
    cat <<'EOF'
用法: devbox <命令>

  pi-web start    后台启动 pi-web (nohup, 日志追加到 /root/.pi-web.log)
  pi-web stop     停止 pi-web
  pi-web restart  重启 pi-web
  pi-web status   查看 pi-web 运行状态
  pi-kill         一键清理所有 pi 进程 (含 pi-web 里运行的会话, 不影响 pi-web 服务本身)

  easytier start    后台启动 easytier-core (nohup, 日志追加到 /root/easytier/logs/easytier-core.log)
  easytier stop     停止 easytier-core (SIGTERM, 最多等 8 秒后强杀)
  easytier restart  重启 easytier-core
  easytier kill     强制结束 easytier-core (SIGKILL)
  easytier status   查看 easytier-core 运行状态, 虚拟 IP 与对等节点
  easytier log      实时查看 easytier-core 日志 (Ctrl-C 退出)

  help         显示本帮助
EOF
}

# --- pi-web 启停 ---
# pi-web 父进程收到 SIGTERM 会转发给 next 子进程并随之退出 (其内部 5 秒强杀兜底),
# 因此 stop 只需 kill 父进程, 整棵进程树可干净退出

web_status() {
    if [ -z "$PI_WEB_BIN" ]; then
        echo "pi-web 未安装"
        return 0
    fi
    pids="$(pgrep -f "${PI_WEB_BIN}( |$)" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        echo "pi-web 未在运行"
    else
        echo "pi-web 运行中 (PID: $(echo $pids | tr '\n' ' '))"
        echo "监听: 0.0.0.0:${PI_WEB_PORT}  日志: ${PI_WEB_LOG}"
    fi
}

web_start() {
    if [ -z "$PI_WEB_BIN" ]; then
        echo "错误: 未找到 pi-web 命令" >&2
        exit 1
    fi
    if pgrep -f "${PI_WEB_BIN}( |$)" >/dev/null 2>&1; then
        echo "pi-web 已在运行, 如需重启请用: devbox web restart"
        return 0
    fi
    # nohup 脱离 SSH 会话的 SIGHUP, 容器无 systemd 故以此方式常驻
    # 端口走自定义变量 PI_WEB_PORT 并以 CLI 参数传入, 不依赖 PORT (该变量太常见易与其他程序冲突)
    nohup "$PI_WEB_BIN" --port "$PI_WEB_PORT" >>"$PI_WEB_LOG" 2>&1 &
    web_pid=$!
    # 轮询端口等待就绪, 拿到任何 HTTP 响应(含 401 未认证)都算就绪
    waited=0
    while [ "$waited" -lt 15 ]; do
        if curl -s -o /dev/null "http://127.0.0.1:${PI_WEB_PORT}/"; then
            echo "pi-web 已就绪: http://<宿主机IP>:${PI_WEB_PORT} (密码见 PI_WEB_PASSWORD)"
            return 0
        fi
        if ! kill -0 "$web_pid" 2>/dev/null; then
            echo "错误: pi-web 启动失败, 最近日志:" >&2
            tail -n 20 "$PI_WEB_LOG" >&2 || true
            exit 1
        fi
        waited=$((waited + 1))
        sleep 1
    done
    echo "pi-web 启动超时, 进程仍在运行, 可查看日志: ${PI_WEB_LOG}"
}

web_stop() {
    pids="$(pgrep -f "${PI_WEB_BIN}( |$)" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        echo "pi-web 未在运行"
        return 0
    fi
    kill -TERM $pids 2>/dev/null || true
    waited=0
    while pgrep -f "${PI_WEB_BIN}( |$)" >/dev/null 2>&1 && [ "$waited" -lt 8 ]; do
        waited=$((waited + 1))
        sleep 1
    done
    # 等待后仍未退出的残余进程强杀
    pkill -KILL -f "${PI_WEB_BIN}( |$)" 2>/dev/null || true
    echo "pi-web 已停止"
}

# --- easytier 启停 ---
# 二进制由镜像预装, 网络行为完全由配置文件描述, 本工具不解析配置内容

# PID 文件可能在进程被外部杀死后残留, 因此只在 /proc 中进程存活且进程名匹配时才采信, 否则回退到 pgrep
et_pid() {
    # 未预装二进制时直接返回空, 避免用空字符串拼出的模式去 pgrep 误伤无关进程
    [ -n "$ET_BIN" ] || return 0
    if [ -f "$ET_PID_FILE" ]; then
        et_file_pid="$(head -n1 "$ET_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$et_file_pid" ] && [ -d "/proc/$et_file_pid" ] \
            && [ "$(cat "/proc/$et_file_pid/comm" 2>/dev/null)" = "easytier-core" ]; then
            printf '%s' "$et_file_pid"
            return 0
        fi
    fi
    pgrep -f "${ET_BIN}( |$)" 2>/dev/null | head -n1
}

et_status() {
    if [ -z "$ET_BIN" ]; then
        echo "easytier-core 未安装"
        return 0
    fi
    et_cur_pid="$(et_pid)"
    if [ -z "$et_cur_pid" ]; then
        echo "easytier 未在运行"
        return 0
    fi
    echo "easytier 运行中 (PID: ${et_cur_pid})"
    echo "配置: ${ET_CONFIG}"
    echo "日志: ${ET_LOG}"
    # 监听地址与虚拟 IP 由 easytier-cli 自报, 不解析配置文件; rpc portal 尚未就绪时 cli 会失败, 属正常情况
    # cli 的 stdout 若直接接到使用者的管道, 管道被提前关闭(如 devbox easytier status | head)时它会因
    # Broken pipe panic 并在当前目录留下约 45MB 的 core 文件, 所以先整段读进变量, 再由本脚本打印
    if [ -n "$ET_CLI_BIN" ]; then
        for et_cli_subcmd in node peer; do
            et_cli_out="$("$ET_CLI_BIN" "$et_cli_subcmd" 2>/dev/null || true)"
            if [ -n "$et_cli_out" ]; then
                printf '%s\n' "$et_cli_out" || true
            fi
        done
    fi
}

# 按大小轮转 nohup 捕获的日志: 超过 ET_LOG_MAX_SIZE 就把存量顺次后移归档, 只保留 ET_LOG_ARCHIVE_COUNT 份
# 不用 easytier 自带的 --file-log-level: 它内部是 BufWriter 且没有周期性 flush, 进程退出时缓冲里
# 剩余的日志会永久丢失, 而 nohup 重定向是内核直接写文件, 实时且最后一条也不丢
rotate_log() {
    [ -f "$ET_LOG" ] || return 0
    et_log_size="$(wc -c <"$ET_LOG" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$et_log_size" ] || [ "$et_log_size" -le "$ET_LOG_MAX_SIZE" ]; then
        return 0
    fi
    # 从最旧一份开始清, 再逐级后移, 空出 .1 给当前日志
    rm -f "${ET_LOG}.${ET_LOG_ARCHIVE_COUNT}"
    et_archive_no=$((ET_LOG_ARCHIVE_COUNT - 1))
    while [ "$et_archive_no" -ge 1 ]; do
        if [ -f "${ET_LOG}.${et_archive_no}" ]; then
            mv -f "${ET_LOG}.${et_archive_no}" "${ET_LOG}.$((et_archive_no + 1))"
        fi
        et_archive_no=$((et_archive_no - 1))
    done
    mv -f "$ET_LOG" "${ET_LOG}.1"
}

et_start() {
    if [ -z "$ET_BIN" ]; then
        echo "错误: 未找到 easytier-core 命令" >&2
        exit 1
    fi
    if [ ! -f "$ET_CONFIG" ]; then
        echo "错误: 缺少配置文件 ${ET_CONFIG}" >&2
        echo "镜像不预置配置, 请先编写该文件再启动" >&2
        exit 1
    fi
    if [ -n "$(et_pid)" ]; then
        echo "easytier 已在运行, 如需重启请用: devbox easytier restart"
        return 0
    fi
    mkdir -p "${ET_HOME}/logs" "${ET_HOME}/run"
    rotate_log
    # 日志是追加式的, 每次启动插入分隔行便于定位本次运行的起点
    printf '===== %s 启动 =====\n' "$(date '+%F %T')" >>"$ET_LOG"
    # nohup 脱离 SSH 会话的 SIGHUP; 容器无 systemd 故以此方式常驻
    nohup "$ET_BIN" -c "$ET_CONFIG" --console-log-level "$ET_LOG_LEVEL" >>"$ET_LOG" 2>&1 &
    et_start_pid=$!
    printf '%s\n' "$et_start_pid" >"$ET_PID_FILE"
    # 配置文件写错时 core 会立即退出, 所以启动后观察几秒: 秒退即判失败, 并把日志尾部抛给使用者
    waited=0
    while [ "$waited" -lt 3 ]; do
        if ! kill -0 "$et_start_pid" 2>/dev/null; then
            echo "错误: easytier 启动失败, 最近日志:" >&2
            tail -n 20 "$ET_LOG" >&2 || true
            rm -f "$ET_PID_FILE"
            exit 1
        fi
        waited=$((waited + 1))
        sleep 1
    done
    echo "easytier 已启动 (PID: ${et_start_pid})"
    echo "日志: ${ET_LOG}"
}

et_stop() {
    if [ -z "$ET_BIN" ]; then
        echo "easytier-core 未安装"
        return 0
    fi
    et_pids="$(pgrep -f "${ET_BIN}( |$)" 2>/dev/null || true)"
    if [ -z "$et_pids" ]; then
        echo "easytier 未在运行"
        rm -f "$ET_PID_FILE"
        return 0
    fi
    kill -TERM $et_pids 2>/dev/null || true
    waited=0
    while pgrep -f "${ET_BIN}( |$)" >/dev/null 2>&1 && [ "$waited" -lt 8 ]; do
        waited=$((waited + 1))
        sleep 1
    done
    # 等待后仍未退出的残余进程强杀
    pkill -KILL -f "${ET_BIN}( |$)" 2>/dev/null || true
    rm -f "$ET_PID_FILE"
    echo "easytier 已停止"
}

et_kill() {
    if [ -z "$ET_BIN" ]; then
        echo "easytier-core 未安装"
        return 0
    fi
    # 不做优雅等待直接 SIGKILL, 供 stop 卡住时使用
    pkill -KILL -f "${ET_BIN}( |$)" 2>/dev/null || true
    rm -f "$ET_PID_FILE"
    sleep 1
    if pgrep -f "${ET_BIN}( |$)" >/dev/null 2>&1; then
        echo "错误: easytier 进程仍未退出" >&2
        exit 1
    fi
    echo "easytier 已强制结束"
}

et_log() {
    if [ ! -f "$ET_LOG" ]; then
        echo "错误: 日志文件不存在 ${ET_LOG}" >&2
        exit 1
    fi
    # exec 让 Ctrl-C 直接终止 tail 本身, 不留下挂起的 shell
    exec tail -f "$ET_LOG"
}

# --- pi 进程一键清理 ---
# 匹配 pi 二进制完整路径且路径后跟空格或行尾, 因此 /usr/bin/pi 不会误伤 /usr/bin/pi-web

kill_pi() {
    if [ -z "$PI_BIN" ]; then
        echo "错误: 未找到 pi 命令" >&2
        exit 1
    fi
    pids="$(pgrep -f "${PI_BIN}( |$)" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        echo "没有运行中的 pi 进程"
        return 0
    fi
    echo "清理 pi 进程: $(echo $pids | tr '\n' ' ')"
    kill -TERM $pids 2>/dev/null || true
    waited=0
    while pgrep -f "${PI_BIN}( |$)" >/dev/null 2>&1 && [ "$waited" -lt 5 ]; do
        waited=$((waited + 1))
        sleep 1
    done
    pkill -KILL -f "${PI_BIN}( |$)" 2>/dev/null || true
    echo "已清理"
}

case "${1:-help}" in
    pi-web)
        case "${2:-}" in
            start) web_start ;;
            stop) web_stop ;;
            restart) web_stop; web_start ;;
            status) web_status ;;
            *) usage; exit 1 ;;
        esac
        ;;
    easytier)
        case "${2:-}" in
            start) et_start ;;
            stop) et_stop ;;
            restart) et_stop; et_start ;;
            kill) et_kill ;;
            status) et_status ;;
            log) et_log ;;
            *) usage; exit 1 ;;
        esac
        ;;
    pi-kill) kill_pi ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
