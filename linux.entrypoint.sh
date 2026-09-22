#!/bin/sh
set -eu

# 说明 所有配置均可通过 env 覆盖 每次启动重新写入 幂等

# --- 恢复 /root 默认文件 防止 volume 挂载覆盖 ---
cp -an /root-defaults/. /root/ 2>/dev/null || true

# --- 缓存目录 默认在/root 跟着 bind 持久化 ---
mkdir -p /root/go/pkg/mod /root/.cache/go-build /root/.npm /root/.cache/pip

# --- 桥接环境变量到 SSH 登录 shell ---
# sshd 为登录 shell 构建最小环境, 不传播容器 ENV 与 -e 注入的变量,
# 写入 /etc/environment 由 pam_env 在每次登录时加载, 每次启动重写 幂等
# 取值来自容器环境最终值(镜像 ENV 与 docker run -e 合并结果), 兜底值仅为防御
cat > /etc/environment <<EOF
LANG=${LANG:-C.UTF-8}
LANGUAGE=${LANGUAGE:-C.UTF-8}
PIP_BREAK_SYSTEM_PACKAGES=${PIP_BREAK_SYSTEM_PACKAGES:-1}
PORT=${PORT:-10001}
PI_WEB_HOSTNAME=${PI_WEB_HOSTNAME:-0.0.0.0}
PI_WEB_NO_OPEN=${PI_WEB_NO_OPEN:-1}
PI_WEB_PASSWORD=${PI_WEB_PASSWORD:-}
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

# --- Git 用 SSH 私钥 ---
if [ -n "${GIT_SSH_PRIVATE_KEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    printf '%s\n' "$GIT_SSH_PRIVATE_KEY" > /root/.ssh/id_ed25519
    chmod 600 /root/.ssh/id_ed25519
fi

# --- SSH authorized_keys ---
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null \
        || printf '%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
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

# --- 启动 ---
ssh-keygen -A >/dev/null 2>&1 || true
exec /usr/sbin/sshd -D -e
