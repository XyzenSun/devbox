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

# 自定义 entrypoint 装到独立路径 不覆盖原镜像的 /usr/local/bin/entrypoint.sh
# 由自定义脚本在执行完机器特有逻辑后委托原 entrypoint
COPY custom.entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# 覆盖基础镜像的 CMD 改为启动自定义 entrypoint
CMD ["/usr/local/bin/custom-entrypoint.sh"]
