#!/usr/bin/env bash
# 打包可分发产物：dist/SimplePlayer.app 与 dist/SimplePlayer.dmg
#
# 步骤：Release 构建 → macdeployqt 部署 Qt/QML → 修正 rpath → 补齐第三方 dylib
#       → ad-hoc 签名 → 生成 DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QTPREFIX="$(brew --prefix qt@6)"
APP="$ROOT/dist/SimplePlayer.app"
DMG="$ROOT/dist/SimplePlayer.dmg"

echo "==> 构建"
cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$ROOT/build" -j"$(sysctl -n hw.ncpu)"

echo "==> 部署 Qt / QML"
# Finder / Spotlight 可能在这里重建 .DS_Store，导致 rm -rf 偶发「目录非空」
rm -rf "$ROOT/dist" || rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
cp -R "$ROOT/build/SimplePlayer.app" "$APP"
"$QTPREFIX/bin/macdeployqt" "$APP" -qmldir="$ROOT/src/qml" -always-overwrite 2> >(
        # macdeployqt 把所有 debug 日志都用 "ERROR:" 前缀，包括正常的 rpath 排查过程，
        # 过滤掉这两条噪音行，让真正的错误露出来
        grep -v '^ERROR: Cannot resolve rpath' | grep -v '^ERROR:  using QList' >&2
    )

echo "==> 修正 rpath"
BIN="$APP/Contents/MacOS/SimplePlayer"
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN" 2>/dev/null || true
install_name_tool -delete_rpath /opt/homebrew/lib "$BIN" 2>/dev/null || true

echo "==> 补齐第三方 dylib / Qt 框架"
python3 - "$APP" "$QTPREFIX/lib" <<'PY'
import os, shutil, subprocess, sys

app, qtlib = sys.argv[1], sys.argv[2]
fw = os.path.join(app, "Contents/Frameworks")
search = [qtlib, "/opt/homebrew/lib", "/opt/homebrew/opt"]


def machos():
    for root, _, files in os.walk(app):
        if "/Resources/engine" in root:
            continue
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p):
                continue
            try:
                with open(p, "rb") as fh:
                    magic = fh.read(4)
            except OSError:
                continue
            # Mach-O 64 位（小端）/ 通用二进制
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                yield p


def deps_of(p):
    out = subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout
    lines = out.splitlines()
    if not lines:
        return None, []
    deps = [l.strip().split(" (compatibility")[0] for l in lines[1:]]

    # otool -L 的第 2 行只有带 LC_ID_DYLIB 的库才是自身 ID；
    # 可执行文件和插件模块没有 install ID，第 2 行其实是第一个依赖。
    # 用 otool -D 判断，避免把第一个依赖误当成 ID 丢掉
    # （否则插件依赖的样式框架 / 第三方库永远不会被补齐）。
    own_out = subprocess.run(["otool", "-D", p], capture_output=True, text=True).stdout
    own_lines = own_out.splitlines()
    own = own_lines[1].strip() if len(own_lines) > 1 else ""
    if own and deps and deps[0] == own:
        deps = deps[1:]
    return own, deps


EXTERNAL = ("/opt/homebrew", "/usr/local", "@executable_path/../lib")


def find_src(name):
    for base in search:
        cand = os.path.join(base, name)
        if os.path.exists(cand):
            return cand
    return None


# 1) 拷贝缺失的 Qt 框架与第三方 dylib
for _ in range(8):
    changed = 0
    for p in machos():
        _, deps = deps_of(p)
        for ref in deps:
            if ref.startswith(("/usr/lib/", "/System/")):
                continue
            name = os.path.basename(ref)
            if ".framework" in ref:
                fwname = ref.split(".framework")[0].split("/")[-1] + ".framework"
                dst = os.path.join(fw, fwname)
                if not os.path.isdir(dst):
                    src = find_src(fwname)
                    if src:
                        shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
                        changed += 1
                continue
            dst = os.path.join(fw, name)
            if not os.path.exists(dst):
                src = find_src(name)
                if src:
                    shutil.copy2(src, dst)
                    changed += 1
                else:
                    print("  缺少依赖:", ref, "<-", os.path.basename(p))
    if changed == 0:
        break

# 2) 把绝对路径依赖改成 @rpath
for p in machos():
    _, deps = deps_of(p)
    for ref in deps:
        if not ref.startswith(EXTERNAL):
            continue
        if ".framework" in ref:
            fwname = ref.split(".framework")[0].split("/")[-1] + ".framework"
            tail = ref.split(fwname + "/", 1)[1] if fwname + "/" in ref else ""
            new = "@rpath/" + fwname + ("/" + tail if tail else "")
        else:
            new = "@rpath/" + os.path.basename(ref)
        subprocess.run(["install_name_tool", "-change", ref, new, p], capture_output=True)

# 3) 重写自身 install ID，保证可重定位
for p in machos():
    own, _ = deps_of(p)
    if not own or not own.startswith(EXTERNAL):
        continue
    new = "@rpath/" + os.path.relpath(p, fw)
    subprocess.run(["install_name_tool", "-id", new, p], capture_output=True)
PY

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "==> 生成 DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SimplePlayer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> 完成：$DMG ($(du -sh "$DMG" | cut -f1))"
