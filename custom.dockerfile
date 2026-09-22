# 以 GHCR 预构建镜像为基础 只叠加自定义 entrypoint 不重复构建完整镜像
FROM ghcr.io/xyzensun/devbox-linux:latest

# 自定义 entrypoint 装到独立路径 不覆盖原镜像的 /usr/local/bin/entrypoint.sh
# 由自定义脚本在执行完机器特有逻辑后委托原 entrypoint
COPY custom.entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

# 覆盖基础镜像的 CMD 改为启动自定义 entrypoint
CMD ["/usr/local/bin/custom-entrypoint.sh"]
