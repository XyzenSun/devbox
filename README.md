# devbox

容器化开发环境镜像，提供 Go / TypeScript / Python 三语言工具链与 SSH 接入，内置 [pi](https://github.com/earendil-works/pi) 编程智能体、pi-web 浏览器界面与 pi-sync 多机配置同步。提供 Linux 与 macOS 两套构建：Linux 版缓存跟随 `/root` bind 持久化到宿主机；macOS 版缓存放在容器内 `/cache`，避开 macOS 文件共享的性能开销。

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
| `internal-scripts/devbox.sh` | 安装为容器内 `devbox` 命令，提供 pi-web 启停与 pi 进程一键清理（容器无 systemd） |
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

## 运行时环境变量

在 compose 文件的 `environment` 段直接填写，无需 .env 文件。所有变量均可省略，省略时仅跳过对应配置。

| 变量 | 用途 |
| --- | --- |
| `PI_WEB_PASSWORD` | pi-web 登录密码，默认 `devbox-pi-web` |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | 启动时写入容器内 Git 全局配置 |
| `SSH_PRIVATE_KEY` | 写入 `/root/.ssh/id_ed25519` 的私钥内容（容器出站 SSH，git 走 `~/.ssh` 自动使用）；未填 `SSH_PUBLIC_KEY` 时自动从它导出公钥 |
| `SSH_PUBLIC_KEY` | 写入 `/root/.ssh/authorized_keys` 与 `/root/.ssh/id_ed25519.pub`；留空则由 `SSH_PRIVATE_KEY` 自动派生，无需手填以免粘贴出错 |
| `ROOT_PASSWORD` | root 密码，设置后才开启 SSH 密码登录，否则仅密钥登录 |
| `SSH_PORT` | 容器内 sshd 监听端口，默认 22222 |
