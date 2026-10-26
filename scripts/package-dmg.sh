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
rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
cp -R "$ROOT/build/SimplePlayer.app" "$APP"
"$QTPREFIX/bin/macdeployqt" "$APP" -qmldir="$ROOT/src/qml" -always-overwrite

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
    # 第 1 行是文件名，第 2 行是文件自身的 install ID，其后才是依赖
    own = lines[1].strip().split(" (compatibility")[0] if len(lines) > 1 else ""
    return own, [l.strip().split(" (compatibility")[0] for l in lines[2:]]


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
