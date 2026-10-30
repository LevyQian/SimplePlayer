#!/bin/bash
# post-update.sh — SimplePlayer 自更新脚本
# 用法：post-update.sh <dmg-path> <app-name>
#
# 由 UpdateChecker 下载完 DMG 后 fork 出去执行：
#   1. 挂载 DMG
#   2. 通知 + 优雅退出当前 app
#   3. 替换 /Applications 里的 .app
#   4. 卸载 DMG + 重启

set -e

DMG_PATH="$1"
APP_NAME="${2:-SimplePlayer}"

if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    echo "post-update.sh: DMG not found: $DMG_PATH" >&2
    exit 1
fi

echo "[post-update] DMG = $DMG_PATH"
echo "[post-update] APP = $APP_NAME"

# ---- 1. 挂载 DMG ----
ATTACH_OUTPUT=$(hdiutil attach -nobrowse -plist "$DMG_PATH" 2>&1)
echo "[post-update] hdiutil attach: $ATTACH_OUTPUT"

# 从输出里找 mount point（/Volumes/xxx）
# -plist 输出形如 <string>/Volumes/SimplePlayer</string>，按 <string> 元素提取，
# 既避开 XML 闭合标签，也能处理 "SimplePlayer 1" 这种带空格的挂载名
MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | grep -oE '<string>/Volumes/[^<]+' \
    | sed 's|<string>||' | head -1)
if [ -z "$MOUNT_POINT" ]; then
    echo "[post-update] Failed to find mount point" >&2
    exit 1
fi
echo "[post-update] Mounted at: $MOUNT_POINT"

DMG_APP="$MOUNT_POINT/$APP_NAME.app"
if [ ! -d "$DMG_APP" ]; then
    # 有些 DMG 会把 app 放在根目录下不同位置，兜底搜一下
    DMG_APP=$(find "$MOUNT_POINT" -name "$APP_NAME.app" -maxdepth 2 -type d 2>/dev/null | head -1)
fi

if [ -z "$DMG_APP" ] || [ ! -d "$DMG_APP" ]; then
    echo "[post-update] .app not found in DMG" >&2
    hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
    exit 1
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

# ---- 3. 替换 .app ----
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

echo "[post-update] Installing to $TARGET_APP"

# 如果旧版本存在，先移到废纸篓（保留用户数据）
if [ -d "$TARGET_APP" ]; then
    mv "$TARGET_APP" "$HOME/.Trash/${APP_NAME}.app.$(date +%s)" 2>/dev/null || true
fi

# 把新 .app 复制过去
cp -R "$DMG_APP" "$TARGET_APP"
chmod -R +x "$TARGET_APP" 2>/dev/null || true

# ---- 4. 卸载 DMG ----
echo "[post-update] Detaching $MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" 2>/dev/null || true

# ---- 5. 重启 ----
echo "[post-update] Relaunching $TARGET_APP"
open "$TARGET_APP"

echo "[post-update] Done."
exit 0
