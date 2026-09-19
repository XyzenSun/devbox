# 容器化开发环境 - Go TS Python(不用Venv) - Linux 版
# 缓存保持默认位置(/root) 跟着 bind 持久化 bind 在Linux上无额外开销

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

ENV PATH=$PATH:/usr/local/go/bin:/root/go/bin:/root/.local/bin

# 配置Python 解除 system pip limit 配置pip镜像

ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN apt-get install -y --no-install-recommends  python3 python3-pip \
    && pip3 config set --global global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

# GO 安装与配置国内镜像和工具链 自适应架构

ARG GOLANG_VERSION=1.27.1

RUN arch="$(dpkg --print-architecture)" \
    && wget -q https://go.dev/dl/go${GOLANG_VERSION}.linux-${arch}.tar.gz \
    && tar -C /usr/local -xzf go${GOLANG_VERSION}.linux-${arch}.tar.gz \
    && rm -f go${GOLANG_VERSION}.linux-${arch}.tar.gz \
    && go env -w GOPROXY=https://goproxy.cn,direct \
    && go install -v golang.org/x/tools/gopls@latest \
    && go install -v github.com/go-delve/delve/cmd/dlv@latest \
    && go install -v honnef.co/go/tools/cmd/staticcheck@latest \
    && go clean -modcache \
    && go clean -cache

# 配置GOPATH

ENV  GOPATH=/root/go

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

# 备份 /root，防止 volume 挂载覆盖镜像内文件
RUN set -eux; \
    mkdir -p /root-defaults; \
    cp -a /root/. /root-defaults/

# 入口脚本 启动时恢复 /root 并注入 git ssh 配置
COPY linux.entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
EXPOSE 22222
CMD ["/usr/local/bin/entrypoint.sh"]
