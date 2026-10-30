#!/bin/bash
# post-update.sh — SimplePlayer 自更新脚本
# 用法：post-update.sh <dmg-path> <app-name>
#
# 由 UpdateChecker 下载完 DMG 后 fork 出去执行：
#   1. 挂载 DMG
#   2. 通知 + 优雅退出当前 app
#   3. 备份旧版 → 复制新版 → 校验 → 删除备份
#   4. 卸载 DMG + 删除下载包 + 重启
# 失败时回滚旧版并重新打开，保证用户始终有一个可用的 App。

set -e

DMG_PATH="$1"
APP_NAME="${2:-SimplePlayer}"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
BACKUP_APP="/tmp/${APP_NAME}.bak.app"
MOUNT_POINT=""

# 退出时统一收尾：先卸载，再删除下载包（成功/失败都不再需要它）。
# 卸载失败说明卷仍被占用，此时保留 DMG，避免留下"已删除底层文件"的挂载卷。
cleanup() {
    if [ -n "$MOUNT_POINT" ]; then
        if ! hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then
            echo "[post-update] detach failed, keep DMG: $DMG_PATH" >&2
            return
        fi
    fi
    rm -f "$DMG_PATH"
}
trap cleanup EXIT

# 失败处理：能回滚就回滚，并确保用户仍有可启动的 App
fail() {
    echo "[post-update] FAILED: $*" >&2

    if [ -d "$BACKUP_APP" ] && [ ! -d "$TARGET_APP" ]; then
        echo "[post-update] Rolling back to previous version"
        mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
    fi
    if [ -d "$TARGET_APP" ]; then
        open "$TARGET_APP" 2>/dev/null || true
    fi
    exit 1
}

if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    echo "post-update.sh: DMG not found: $DMG_PATH" >&2
    exit 1
fi

echo "[post-update] DMG = $DMG_PATH"
echo "[post-update] APP = $APP_NAME"

# ---- 1. 挂载 DMG ----
ATTACH_OUTPUT=$(hdiutil attach -nobrowse -plist "$DMG_PATH" 2>&1) \
    || fail "hdiutil attach failed"
echo "[post-update] hdiutil attach: $ATTACH_OUTPUT"

# 从输出里找 mount point（/Volumes/xxx）
# -plist 输出形如 <string>/Volumes/SimplePlayer</string>，按 <string> 元素提取，
# 既避开 XML 闭合标签，也能处理 "SimplePlayer 1" 这种带空格的挂载名
MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | grep -oE '<string>/Volumes/[^<]+' \
    | sed 's|<string>||' | head -1)
if [ -z "$MOUNT_POINT" ]; then
    fail "Failed to find mount point"
fi
echo "[post-update] Mounted at: $MOUNT_POINT"

DMG_APP="$MOUNT_POINT/$APP_NAME.app"
if [ ! -d "$DMG_APP" ]; then
    # 有些 DMG 会把 app 放在根目录下不同位置，兜底搜一下
    DMG_APP=$(find "$MOUNT_POINT" -name "$APP_NAME.app" -maxdepth 2 -type d 2>/dev/null | head -1)
fi

if [ -z "$DMG_APP" ] || [ ! -d "$DMG_APP" ]; then
    fail ".app not found in DMG"
fi

# ---- 2. 优雅退出当前 app ----
echo "[post-update] Quitting $APP_NAME..."
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true

# 等进程真退出（最多 5 秒）
for i in $(seq 1 50); do
    if ! pgrep -f "$APP_NAME.app" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# 兜底：强杀残留
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5

# ---- 3. 备份旧版（失败时才能回滚；不再扔废纸篓，避免永久占用空间） ----
if [ -d "$TARGET_APP" ]; then
    echo "[post-update] Backing up $TARGET_APP"
    rm -rf "$BACKUP_APP"
    mv "$TARGET_APP" "$BACKUP_APP" \
        || fail "cannot move old app (check /Applications write permission)"
fi

# mv 后目标必须不存在，否则 cp -R 会与旧 bundle 合并，留下过期文件
if [ -d "$TARGET_APP" ]; then
    fail "old app still present, abort to avoid merging"
fi

# ---- 4. 复制新版并校验 ----
echo "[post-update] Installing to $TARGET_APP"
cp -R "$DMG_APP" "$TARGET_APP" || fail "copy failed"
chmod -R +x "$TARGET_APP" 2>/dev/null || true

if [ ! -d "$TARGET_APP" ]; then
    fail "target app missing after copy"
fi

# ---- 5. 成功：删除备份 ----
rm -rf "$BACKUP_APP"

# ---- 6. 重启（DMG 的卸载与删除由 cleanup 统一处理） ----
echo "[post-update] Relaunching $TARGET_APP"
open "$TARGET_APP" 2>/dev/null || true

echo "[post-update] Done."
exit 0
