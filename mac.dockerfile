# 容器化开发环境 - Go TS Python(不用Venv) - macOS 版
# 缓存放/cache 走容器内文件系统 避开 macOS 文件共享开销

# Debian13 slim 基础镜像
FROM debian:13-slim

# 运行时环境变量

ENV LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8

# 更新APT 安装系统基础工具 

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates  curl git nano openssh-client openssh-server  unzip zip vim wget \
    && apt-get autoremove -y \
    && apt-get clean

# Git与SSH配置
RUN git config --system tag.gpgSign false \
    && git config --system commit.gpgsign false \
    && mkdir -p /run/sshd \
    && sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 安装语言环境 运行时

ENV PATH=$PATH:/usr/local/go/bin:/root/go/bin:/root/.local/bin \
    GOPATH=/root/go

# 缓存目录 统一放/cache 不挂载 走容器内原生文件系统 随容器删除一起回收
ENV GOMODCACHE=/cache/go-mod \
    GOCACHE=/cache/go-build \
    npm_config_cache=/cache/npm \
    PIP_CACHE_DIR=/cache/pip

# 配置Python 解除 system pip limit 配置pip镜像

ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN apt-get install -y --no-install-recommends  python3 python3-pip \
    && pip3 config set --global global.index-url https://mirrors.aliyun.com/pypi/simple/ \
    && apt-get autoremove -y \
    && apt-get clean

# GO 安装与配置国内镜像和工具链 自适应架构与最新稳定版

# 从官方 API 获取最新稳定版号, 避免手动维护版本
RUN go_version="$(curl -fsSL 'https://go.dev/dl/?mode=json' | grep -oE '"version": ?"go[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" \
    && arch="$(dpkg --print-architecture)" \
    && wget -q https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz \
    && tar -C /usr/local -xzf go${go_version}.linux-${arch}.tar.gz \
    && rm -f go${go_version}.linux-${arch}.tar.gz \
    && go env -w GOPROXY=https://goproxy.cn,direct \
    && go install -v golang.org/x/tools/gopls@latest \
    && go install -v github.com/go-delve/delve/cmd/dlv@latest \
    && go install -v honnef.co/go/tools/cmd/staticcheck@latest \
    && go clean -modcache \
    && go clean -cache

#配置Nodejs与TS 配置镜像源
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get autoremove -y \
    && apt-get clean \
    && npm config set registry https://registry.npmmirror.com --location=global \
    && npm install -g typescript ts-node \
    && npm cache clean --force

# shell增强： 补全 (bash-completion) 

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash-completion \
    && apt-get autoremove -y \
    && apt-get clean \
    && printf '%s\n' \
        '' \
        '# bash-completion: 终端窗口(交互式非登录 shell)也启用补全' \
        'if ! shopt -oq posix; then' \
        '    if [ -f /usr/share/bash-completion/bash_completion ]; then' \
        '        . /usr/share/bash-completion/bash_completion' \
        '    elif [ -f /etc/bash_completion ]; then' \
        '        . /etc/bash_completion' \
        '    fi' \
        'fi' \
        >> /etc/bash.bashrc

# AI工具

## PI及其依赖与webui安装
# fd-find ripgrep 为 PI 运行时依赖, Debian 的 fd-find 包二进制名为 fdfind, 软链成 fd 方便 shell 直接调用
RUN apt-get update \
    && apt-get install -y --no-install-recommends fd-find ripgrep \
    && apt-get autoremove -y \
    && apt-get clean \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && npm install -g @earendil-works/pi-coding-agent \
    && npm install -g @agegr/pi-web \
    && npm cache clean --force
#PI Web 配置 (默认值, SSH 登录 shell 由 entrypoint 桥接写入 /etc/environment, 运行时 -e 可覆盖)
ENV PORT=10001 \
    PI_WEB_HOSTNAME=0.0.0.0 \
    PI_WEB_NO_OPEN=1 \
    PI_WEB_PASSWORD=devbox-pi-web
## PI插件安装
RUN pi install npm:@xyzensun/pi-sync

# 入口脚本 启动时恢复 /root 并注入 git ssh 配置
# devbox 容器内管理命令 pi-web 启停 与 pi 进程一键清理
COPY mac.entrypoint.sh /usr/local/bin/entrypoint.sh
COPY internal-scripts/devbox.sh /usr/local/bin/devbox
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/devbox

# 备份 /root，防止 volume 挂载覆盖镜像内文件
RUN set -eux; \
    mkdir -p /root-defaults; \
    cp -a /root/. /root-defaults/

WORKDIR /workspace
EXPOSE 22222 10001
CMD ["/usr/local/bin/entrypoint.sh"]
