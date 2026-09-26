# devbox

容器化开发环境镜像，提供 Go / TypeScript / Python 三语言工具链与 SSH 接入，内置 [pi](https://github.com/earendil-works/pi) 编程智能体、pi-web 浏览器界面、pi-sync 多机配置同步与 [EasyTier](https://github.com/EasyTier/EasyTier) 组网工具。提供 Linux 与 macOS 两套构建：Linux 版缓存跟随 `/root` bind 持久化到宿主机；macOS 版缓存放在容器内 `/cache`，避开 macOS 文件共享的性能开销。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `linux.dockerfile` | Linux 版镜像构建，基于 Debian 13 slim，缓存放 `/root` 跟随 bind 持久化 |
| `linux.entrypoint.sh` | Linux 版入口脚本，启动时恢复 `/root` 默认文件、把容器环境变量桥接到 SSH 登录 shell、注入 Git/SSH 配置并启动 sshd |
| `mac.dockerfile` | macOS 版镜像构建，与 Linux 版内容一致，差异是缓存目录统一指向容器内 `/cache` |
| `mac.entrypoint.sh` | macOS 版入口脚本，在 Linux 版基础上多桥接四个缓存目录环境变量 |
| `docker-compose.local.yml` | 本地构建运行，直接使用仓库里的 `linux.dockerfile` |
| `docker-compose.ghcr.yml` | 直接运行 GitHub Action 构建推送的 GHCR 镜像，无需本地构建 |
| `docker-compose.custom.yml` | 以 GHCR 镜像为基础叠加本地自定义扩展运行，适合多机共用同一基础镜像再做少量差异化 |
| `custom.dockerfile` | 自定义扩展的构建文件，`FROM` GHCR 镜像后仅替换入口脚本 |
| `custom.entrypoint.sh` | 自定义入口脚本模板，先执行机器特有逻辑，再委托原镜像的入口脚本 |
| `internal-scripts/devbox.sh` | 安装为容器内 `devbox` 命令，提供 pi-web 与 easytier 启停、pi 进程一键清理（容器无 systemd） |
| `.github/workflows/build-push.yaml` | GitHub Action，手动触发，按 mac/linux 两种变体各自构建 amd64/arm64 并推送 `ghcr.io/xyzensun/devbox-{mac,linux}`，tag 为 `latest` 与 7 位 commit sha |

## 使用

三种运行方式任选其一，均在仓库根目录执行：

```bash
# 本地构建
docker compose -f docker-compose.local.yml up -d --build

# 使用 GHCR 预构建镜像
docker compose -f docker-compose.ghcr.yml up -d

# 基础镜像 + 本地自定义扩展
docker compose -f docker-compose.custom.yml up -d --build
```

启动后 `ssh root@localhost -p 22222` 进入容器，浏览器访问 `http://localhost:10001` 使用 pi-web（默认密码 `devbox-pi-web`）。`/root` 持久化在 `./data/root`，代码目录为 `./workspace`。

容器内使用 `devbox` 命令管理服务：`devbox pi-web start` 后台启动 pi-web（日志在 `/root/.pi-web.log`），`devbox pi-web stop` 停止，`devbox pi-kill` 一键清理所有 pi 进程。

镜像预装 EasyTier 组网工具（`easytier-core` 与 `easytier-cli`），但不预置配置也不随容器启动。自行编写 `/root/easytier/config/config.toml` 后执行 `devbox easytier start` 拉起，`devbox easytier status` 查看虚拟 IP、监听地址与对等节点，日志在 `/root/easytier/logs/easytier-core.log`（error 级，每次 `start` 前检查大小，超过 5MB 就归档为 `.1`/`.2`/`.3` 并只保留 3 份）。配置放在 `/root` 下跟随 bind 持久化，容器重建不会丢失。`10010/tcp` 与 `10010/udp` 已映射到宿主机，对应配置文件里的 `listeners`，其他节点可直连入站；当前镜像不装 TUN 相关依赖，使用 TUN 模式需自行在 compose 里追加 `/dev/net/tun` 与 `NET_ADMIN`。

## 运行时环境变量

在 compose 文件的 `environment` 段直接填写，无需 .env 文件。所有变量均可省略，省略时仅跳过对应配置。

| 变量 | 用途 |
| --- | --- |
| `PI_WEB_PASSWORD` | pi-web 登录密码，默认 `devbox-pi-web` |
| `PI_WEB_PORT` | pi-web 监听端口，默认 `10001`，需与 compose `ports` 的容器侧映射保持一致 |
| `PI_WEB_ALLOWED_HOSTS` | 额外信任的 Host 名，逗号分隔、精确匹配。通过域名或反向代理暴露到公网时必须声明，否则 Next.js 校验 Host 头失败会拒绝请求（Untrusted request），例如用 `https://devbox.example.com` 访问时填 `devbox.example.com` |
| `PI_WEB_AUTO_RUN` | 设为 `true`/`1`/`yes`/`on` 时，容器启动即自动运行 pi-web（内部执行 `devbox pi-web restart`，幂等），默认不自动 |
| `EASYTIER_AUTO_RUN` | 设为 `true`/`1`/`yes`/`on` 时，容器启动即自动运行 easytier（内部执行 `devbox easytier restart`，幂等），默认不自动。需先自行编写 `/root/easytier/config/config.toml`，未编写时仅告警不阻断启动 |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | 启动时写入容器内 Git 全局配置 |
| `SSH_PRIVATE_KEY` | 写入 `/root/.ssh/id_ed25519` 的私钥内容（容器出站 SSH，git 走 `~/.ssh` 自动使用）；未填 `SSH_PUBLIC_KEY` 时自动从它导出公钥 |
| `SSH_PUBLIC_KEY` | 写入 `/root/.ssh/authorized_keys` 与 `/root/.ssh/id_ed25519.pub`；留空则由 `SSH_PRIVATE_KEY` 自动派生，无需手填以免粘贴出错 |
| `ROOT_PASSWORD` | root 密码，设置后才开启 SSH 密码登录，否则仅密钥登录 |
| `SSH_PORT` | 容器内 sshd 监听端口，默认 22222 |
