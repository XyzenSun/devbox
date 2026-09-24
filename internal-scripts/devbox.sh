#!/bin/sh
# devbox 容器内管理工具
# 容器无 systemd: pi-web 以 nohup 后台常驻, 由本工具启停; pi 为前台交互进程, 可能同时存在多个, 提供一键清理
set -eu

PI_WEB_LOG="/root/.pi-web.log"
PI_WEB_PORT="${PI_WEB_PORT:-10001}"

# 解析实际二进制路径, pgrep 按完整命令行匹配, 避免按进程名误杀无关程序
PI_BIN="$(command -v pi 2>/dev/null || true)"
PI_WEB_BIN="$(command -v pi-web 2>/dev/null || true)"

usage() {
    cat <<'EOF'
用法: devbox <命令>

  pi-web start    后台启动 pi-web (nohup, 日志追加到 /root/.pi-web.log)
  pi-web stop     停止 pi-web
  pi-web restart  重启 pi-web
  pi-web status   查看 pi-web 运行状态
  pi-kill         一键清理所有 pi 进程 (含 pi-web 里运行的会话, 不影响 pi-web 服务本身)
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
    pi-kill) kill_pi ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
esac
