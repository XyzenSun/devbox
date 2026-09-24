#!/bin/sh
set -eu

# 说明 所有配置均可通过 env 覆盖 每次启动重新写入 幂等

# --- 恢复 /root 默认文件 防止 volume 挂载覆盖 ---
cp -an /root-defaults/. /root/ 2>/dev/null || true

# --- 缓存目录 不挂载 走容器内文件系统 随容器删除一起回收 ---
mkdir -p /cache/go-mod /cache/go-build /cache/npm /cache/pip

# --- 桥接环境变量到 SSH 登录 shell ---
# sshd 为登录 shell 构建最小环境, 不传播容器 ENV 与 -e 注入的变量,
# 写入 /etc/environment 由 pam_env 在每次登录时加载, 每次启动重写 幂等
# 取值来自容器环境最终值(镜像 ENV 与 docker run -e 合并结果), 兜底值仅为防御
cat > /etc/environment <<EOF
LANG=${LANG:-C.UTF-8}
LANGUAGE=${LANGUAGE:-C.UTF-8}
PIP_BREAK_SYSTEM_PACKAGES=${PIP_BREAK_SYSTEM_PACKAGES:-1}
GOMODCACHE=${GOMODCACHE:-/cache/go-mod}
GOCACHE=${GOCACHE:-/cache/go-build}
npm_config_cache=${npm_config_cache:-/cache/npm}
PIP_CACHE_DIR=${PIP_CACHE_DIR:-/cache/pip}
PI_WEB_PORT=${PI_WEB_PORT:-10001}
PI_WEB_HOSTNAME=${PI_WEB_HOSTNAME:-0.0.0.0}
PI_WEB_NO_OPEN=${PI_WEB_NO_OPEN:-1}
PI_WEB_PASSWORD=${PI_WEB_PASSWORD:-}
PI_WEB_ALLOWED_HOSTS=${PI_WEB_ALLOWED_HOSTS:-}
GOPATH=${GOPATH:-/root/go}
PATH=${PATH}
EOF

# --- Git ---
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# --- root 用户 SSH 私钥 写入 /root/.ssh 供容器出站 SSH (git 等) 使用 ---
if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    printf '%s\n' "$SSH_PRIVATE_KEY" > /root/.ssh/id_ed25519
    chmod 600 /root/.ssh/id_ed25519
    # 未显式提供公钥时 从私钥导出 避免手工粘贴公钥出错
    if [ -z "${SSH_PUBLIC_KEY:-}" ]; then
        SSH_PUBLIC_KEY="$(ssh-keygen -y -f /root/.ssh/id_ed25519 2>/dev/null || true)"
        [ -n "$SSH_PUBLIC_KEY" ] || echo "[devbox] 警告: SSH_PRIVATE_KEY 无法导出公钥 (可能带 passphrase), 已跳过 authorized_keys 写入" >&2
    fi
fi

# --- SSH 公钥 authorized_keys 与 /root/.ssh/id_ed25519.pub 同步写入 ---
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null \
        || printf '%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    # .pub 每次覆盖写入 幂等; 与 SSH_PRIVATE_KEY 填同一对钥匙时 /root/.ssh 下公私钥成对
    printf '%s\n' "$SSH_PUBLIC_KEY" > /root/.ssh/id_ed25519.pub
fi

# --- SSH 密码 设了 ROOT_PASSWORD 才开密码登录 ---
if [ -n "${ROOT_PASSWORD:-}" ]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
    SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-yes}"
else
    SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
fi

# --- 运行时 sshd 配置 每次覆盖写 sshd_config.d 优先级高于主配置 ---
mkdir -p /run/sshd /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-env.conf <<EOF
Port ${SSH_PORT:-22222}
PasswordAuthentication ${SSH_PASSWORD_AUTH}
EOF

# --- pi-web 自动启动 (PI_WEB_AUTO_RUN=true/1/yes/on 时开启) ---
# 容器无 systemd, 启动即拉起 pi-web 常驻; restart 幂等安全
# 失败仅告警不阻断 sshd, 稍后可手动 devbox pi-web start
case "$(printf '%s' "${PI_WEB_AUTO_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on)
        devbox pi-web restart || echo "[devbox] 警告: pi-web 自动启动失败, 可稍后手动执行: devbox pi-web start" >&2
        ;;
esac

# --- 启动 ---
ssh-keygen -A >/dev/null 2>&1 || true
exec /usr/sbin/sshd -D -e
