# 以 GHCR 预构建镜像为基础 只叠加自定义 entrypoint 不重复构建完整镜像
FROM ghcr.io/xyzensun/devbox-linux:latest

# crane 直接访问镜像仓库, 无需 Docker daemon; 只安装 crane, 不带其他工具
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) crane_arch=x86_64 ;; \
        arm64) crane_arch=arm64 ;; \
        *) echo '不支持的 crane 架构' >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/crane.tar.gz \
        "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${crane_arch}.tar.gz"; \
    tar -xzf /tmp/crane.tar.gz -C /tmp crane; \
    install -m 0755 /tmp/crane /usr/local/bin/crane; \
    rm -f /tmp/crane.tar.gz /tmp/crane

# tshark 是 Wireshark 的命令行前端, 用于解析 pcap 与容器内实时抓包
# wireshark-common 默认会询问是否给 dumpcap 加 setuid 以允许非 root 抓包, 容器内固定以 root 运行
# 因此预置为 false 跳过交互提问, 也避免在镜像里留下可提权的 setuid 二进制
RUN echo 'wireshark-common wireshark-common/install-setuid boolean false' | debconf-set-selections \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tshark \
    && apt-get clean \
    && tshark --version | head -1

# 自定义 entrypoint 装到独立路径 不覆盖原镜像的 /usr/local/bin/entrypoint.sh
# 由自定义脚本在执行完机器特有逻辑后委托原 entrypoint
COPY custom.entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# 覆盖基础镜像的 CMD 改为启动自定义 entrypoint
CMD ["/usr/local/bin/custom-entrypoint.sh"]
