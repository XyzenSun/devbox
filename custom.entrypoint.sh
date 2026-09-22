#!/bin/sh
set -eu

# 自定义 entrypoint 包装模板
# 在原镜像 entrypoint 之前执行机器特有逻辑, 最后委托原 entrypoint
# 原 entrypoint 保留在 /usr/local/bin/entrypoint.sh 负责恢复 /root 桥接环境变量 启动 sshd

# --- 示例: 机器特有的额外环境变量 ---
# 原 entrypoint 每次启动会用 cat > 整体重写 /etc/environment, 在其之后追加会被下次启动覆盖,
# 且它只写入固定清单, 因此额外变量走 /etc/profile.d 由登录 shell 经 /etc/profile 加载
mkdir -p /etc/profile.d
cat > /etc/profile.d/99-custom-env.sh <<'EOF'
export DEVBOX_CUSTOM_MARKER=custom-entrypoint-loaded
EOF

# --- 示例: 自定义 motd SSH 登录时展示 ---
printf '%s\n' \
    'devbox (custom entrypoint)' \
    '' \
    >> /etc/motd

# --- 委托原镜像 entrypoint (恢复 /root 环境变量桥接 启动 sshd) ---
exec /usr/local/bin/entrypoint.sh
