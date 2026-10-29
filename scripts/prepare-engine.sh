#!/usr/bin/env bash
# 生成随包分发的 AceStream 引擎运行时（third_party/acestream-engine）
#
# 组成：
#   bin/      colima + limactl
#   share/    lima 的模板与脚本（limactl 按相对路径查找，必须保留）
#   libexec/  lima 的 guest agent
#   vm/       colima 用的 Ubuntu 磁盘镜像（避免首次启动联网下载 ~330MB）
#   image/    Ace Stream 引擎容器镜像（docker save 后 gzip）
#
# 依赖：docker（仅用于构建镜像，可用 Docker Desktop 或 colima）、curl、gzip
# 可选环境变量：GH_PROXY（GitHub 加速前缀，默认 https://ghfast.top）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/third_party/acestream-engine"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GH_PROXY="${GH_PROXY:-https://ghfast.top}"
COLIMA_VERSION="${COLIMA_VERSION:-v0.10.3}"
LIMA_VERSION="${LIMA_VERSION:-v2.2.1}"
CORE_VERSION="${CORE_VERSION:-v0.10.4}"
ACE_VERSION="${ACE_VERSION:-3.2.11}"

VM_IMAGE="ubuntu-24.04-minimal-cloudimg-arm64-docker.raw.gz"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-docker.m.daocloud.io}"

echo "==> 下载 colima ${COLIMA_VERSION}"
curl -fL --retry 3 -o "$TMP/colima" \
  "$GH_PROXY/https://github.com/abiosoft/colima/releases/download/${COLIMA_VERSION}/colima-Darwin-arm64"

echo "==> 下载 lima ${LIMA_VERSION}"
curl -fL --retry 3 -o "$TMP/lima.tar.gz" \
  "$GH_PROXY/https://github.com/lima-vm/lima/releases/download/${LIMA_VERSION}/lima-${LIMA_VERSION#v}-Darwin-arm64.tar.gz"

echo "==> 下载 colima 虚拟机镜像（约 330MB）"
curl -fL --retry 3 -o "$TMP/$VM_IMAGE" \
  "$GH_PROXY/https://github.com/abiosoft/colima-core/releases/download/${CORE_VERSION}/${VM_IMAGE}"

echo "==> 下载 Ace Stream 引擎 ${ACE_VERSION}"
curl -fL --retry 3 -o "$TMP/ace-engine.tar.gz" \
  "https://download.acestream.media/linux/acestream_${ACE_VERSION}_ubuntu_22.04_x86_64_py3.10.tar.gz"

echo "==> 组装目录"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/vm" "$OUT/image" "$TMP/lima" "$TMP/ctx"
tar xzf "$TMP/lima.tar.gz" -C "$TMP/lima"

install -m 755 "$TMP/colima" "$OUT/bin/colima"
install -m 755 "$TMP/lima/bin/limactl" "$OUT/bin/limactl"
cp -R "$TMP/lima/share" "$OUT/share"
cp -R "$TMP/lima/libexec" "$OUT/libexec"
# 只保留 vz 驱动与 Linux 客户机所需文件，去掉约 40MB 无关内容
rm -rf "$OUT/share/doc" "$OUT/share/man" \
       "$OUT/share/lima/lima-guestagent.Darwin-aarch64.gz" \
       "$OUT/libexec/lima/lima-driver-krunkit" \
       "$OUT/libexec/lima/limactl-mcp"
cp "$TMP/$VM_IMAGE" "$OUT/vm/$VM_IMAGE"

# colima v0.10+ 强制要求宿主机有 docker CLI 才允许 start（dependency check），
# 但 SimplePlayer 直接通过 socket 连 Docker Engine，不需要 CLI。
# 放一个壳脚本只满足 dependency check：返回 --version/version/context 的基本输出，
# 其他命令如果系统装了真 docker 就透传，否则静默成功。
cat > "$OUT/bin/docker" << 'SHEOF'
#!/bin/sh
# Fake docker CLI — satisfies colima v0.10+ host dependency check.
# SimplePlayer never calls this; it talks directly to Docker Engine via socket.
case "$1" in
    --version)
        echo "Docker version 27.5.1, build mock" ;;
    version)
        echo '{"Server":{"Version":"27.5.1"},"Client":{"Version":"27.5.1"}}' ;;
    context)
        case "$2" in ls|list|use|create|rm|delete|inspect) ;; *) exit 0 ;; esac ;;
    info|ps|images|run|exec|logs|build|compose) exit 0 ;;
    *)
        REAL_DOCKER=$(command -v /usr/local/bin/docker /opt/homebrew/bin/docker /usr/bin/docker 2>/dev/null | head -1)
        if [ -n "$REAL_DOCKER" ]; then
            exec "$REAL_DOCKER" "$@"
        fi
        exit 0 ;;
esac
SHEOF
chmod +x "$OUT/bin/docker"

echo "==> 构建引擎镜像"
mkdir -p "$TMP/ctx/engine"
tar xzf "$TMP/ace-engine.tar.gz" -C "$TMP/ctx/engine"
cat > "$TMP/ctx/Dockerfile" <<DOCKERFILE
FROM ${REGISTRY_MIRROR}/library/ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \\
    LANG=C.UTF-8

COPY engine/ /opt/acestream/

RUN sed -i 's@//archive.ubuntu.com@//mirrors.tuna.tsinghua.edu.cn@g; s@//security.ubuntu.com@//mirrors.tuna.tsinghua.edu.cn@g' /etc/apt/sources.list \\
    && apt-get update \\
    && apt-get install -y --no-install-recommends python3 python3-minimal python3-pip libpython3.10 libpython3.10-stdlib ca-certificates \\
    && python3 -m pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple \\
        apsw pycryptodome lxml psutil pynacl iso8601 aiohttp \\
    && rm -rf /var/lib/apt/lists/*

EXPOSE 6878

CMD ["/opt/acestream/start-engine", "--client-console"]
DOCKERFILE

docker build --platform linux/amd64 -t acestream-engine:local -f "$TMP/ctx/Dockerfile" "$TMP/ctx"
docker save acestream-engine:local | gzip -1 > "$OUT/image/acestream-image.tar.gz"

echo "==> 完成：$(du -sh "$OUT" | cut -f1)  $OUT"
