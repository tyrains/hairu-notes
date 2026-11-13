#!/usr/bin/env bash
# ============================================================================
# 海如便签 —— 本地一键生成 APK
#
# 不需要 Android Studio、不需要 Gradle、不需要联网拉 Maven 依赖。
# 只用到：JDK 17 + curl + python + 两个 Google 官方 SDK 压缩包（首次自动下载）。
#
# 用法（Git Bash）：
#     bash android/build-local.sh
#
# 产物：项目根目录 HaiRuNotes-v1.2.0.apk（已对齐、已 v2/v3 签名，可直接安装）
# 说明：改完 app/index.html 后直接重跑本脚本即可，脚本会自动同步到 assets。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${TN_SDK:-$HOME/.tnbuild-sdk}"
BT="$SDK/build-tools/34.0.0"
PLAT="$SDK/platforms/android-34"
AAPT="$BT/aapt2.exe"
ZIPALIGN="$BT/zipalign.exe"
D8JAR="$BT/lib/d8.jar"
SIGNJAR="$BT/lib/apksigner.jar"
ANDROID_JAR="$PLAT/android.jar"
KEYSTORE="$ROOT/android/turbonotes.jks"
OUT="$ROOT/HaiRuNotes-v1.2.0.apk"
PY="${PYTHON:-python}"

# 签名口令只放在本地私有配置里，不随源码公开；缺失时用占位口令（clone 后会自动新建密钥）
KS_PASS_FILE="$ROOT/android/signing.local.conf"
KS_PASS="hairunotes-local"
if [ -f "$KS_PASS_FILE" ]; then
  . "$KS_PASS_FILE"
fi

PLATFORM_URL="https://dl.google.com/android/repository/platform-34-ext7_r03.zip"
BUILDTOOLS_URL="https://dl.google.com/android/repository/build-tools_r34-windows.zip"

for cmd in java javac keytool curl "$PY"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：$cmd（需要 JDK 17 + curl + python）"; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. 首次运行时准备最小 SDK（约 120 MB，之后复用）
# ---------------------------------------------------------------------------
if [ -f "$AAPT" ] && [ -f "$ZIPALIGN" ] && [ -f "$D8JAR" ] && [ -f "$SIGNJAR" ] && [ -f "$ANDROID_JAR" ]; then
  echo "[1/8] SDK 已就绪：$SDK"
else
  echo "[1/8] 首次运行，下载 Android 34 SDK 最小组件…"
  mkdir -p "$SDK/dl"
  curl -fL --retry 2 -o "$SDK/dl/platform.zip" "$PLATFORM_URL"
  curl -fL --retry 2 -o "$SDK/dl/buildtools.zip" "$BUILDTOOLS_URL"
  "$PY" - "$SDK" <<'PYEOF'
import sys, os, zipfile, shutil
sdk = sys.argv[1]
dl  = os.path.join(sdk, 'dl')
for zipname, root, dest in [('platform.zip', 'android-34', 'platforms/android-34'),
                            ('buildtools.zip', 'android-14', 'build-tools/34.0.0')]:
    tmp = os.path.join(sdk, '_unzip_' + root)
    if os.path.exists(tmp): shutil.rmtree(tmp)
    with zipfile.ZipFile(os.path.join(dl, zipname)) as z: z.extractall(tmp)
    target = os.path.join(sdk, dest)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.exists(target): shutil.rmtree(target)
    shutil.move(os.path.join(tmp, root), target)
    shutil.rmtree(tmp, ignore_errors=True)
    print('  ✓', dest)
PYEOF
fi

# ---------------------------------------------------------------------------
# 2. 准备纯 ASCII 临时工作区（aapt2 等 Windows 工具不擅长中文路径）
# ---------------------------------------------------------------------------
WORK="$(mktemp -d /tmp/tnbuild.XXXXXX)"
trap '[ -n "$WORK" ] && rm -rf "$WORK" || true' EXIT
mkdir -p "$WORK"/{flat,gen,classes,dex,out,src}
cp -r "$ROOT/android/app/src/main/res"    "$WORK/src/res"
cp -r "$ROOT/android/app/src/main/java"   "$WORK/src/java"
mkdir -p "$WORK/src/assets"
cp "$ROOT/app/index.html" "$WORK/src/assets/index.html"
# 同时写回 Gradle 工程，保证 Android Studio / GitHub Actions 出包用的是同一份界面
cp "$ROOT/app/index.html" "$ROOT/android/app/src/main/assets/index.html"
cp "$ROOT/android/app/src/main/AndroidManifest.xml" "$WORK/src/AndroidManifest.xml"
echo "[2/8] 工作区：$WORK（界面已同步到构建目录与 Gradle 工程）"

# Gradle 工程用 namespace 声明包名；手工 aapt2 需要 manifest 里显式写 package
"$PY" - "$WORK/src/AndroidManifest.xml" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
if 'package=' not in s:
    assert old in s, 'AndroidManifest.xml 格式变了，请检查'
    s = s.replace(old, '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.hairu.idea">', 1)
    open(p, 'w', encoding='utf-8').write(s)
print('  ✓ manifest 注入 package=com.hairu.idea（仅构建副本）')
PYEOF

# ---------------------------------------------------------------------------
# 3. 编译资源、链接出基础 APK（含 resources.arsc / assets / 二进制 Manifest）
# ---------------------------------------------------------------------------
echo "[3/8] aapt2 编译资源…"
( cd "$WORK/src/res" && "$AAPT" compile --dir . -o "$WORK/flat/res.zip" )
echo "[4/8] aapt2 链接基础 APK…"
"$AAPT" link \
  -o "$WORK/out/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$WORK/src/AndroidManifest.xml" \
  -A "$WORK/src/assets" \
  --java "$WORK/gen" \
  --min-sdk-version 26 --target-sdk-version 34 \
  --version-code 3 --version-name 1.2.0 \
  "$WORK/flat/res.zip"

# ---------------------------------------------------------------------------
# 4. javac + d8 生成 classes.dex
# ---------------------------------------------------------------------------
echo "[5/8] javac 编译 Java…"
if ! javac -encoding UTF-8 -cp "$ANDROID_JAR" -source 8 -target 8 -d "$WORK/classes" \
  "$WORK/src/java/com/hairu/idea/MainActivity.java" \
  "$WORK/gen/com/hairu/idea/R.java" > "$WORK/javac.log" 2>&1; then
  echo "javac 编译失败："; cat "$WORK/javac.log"; exit 1
fi
echo "[6/8] d8 生成 DEX…"
mapfile -t CLS < <(find "$WORK/classes" -name '*.class' | sort)
java -Xmx1024M -cp "$D8JAR" com.android.tools.r8.D8 \
  --lib "$ANDROID_JAR" --min-api 26 --output "$WORK/dex" "${CLS[@]}"

# ---------------------------------------------------------------------------
# 5. 组装 → 对齐 → 签名
# ---------------------------------------------------------------------------
echo "[7/8] 组装 + zipalign…"
"$PY" - "$WORK" <<'PYEOF'
import sys, zipfile, os
w = sys.argv[1]
zin = zipfile.ZipFile(os.path.join(w, 'out/base.apk'))
zout = zipfile.ZipFile(os.path.join(w, 'out/unsigned.apk'), 'w', zipfile.ZIP_DEFLATED)
for it in zin.infolist():
    zout.writestr(it, zin.read(it.filename))
zout.write(os.path.join(w, 'dex/classes.dex'), 'classes.dex', compress_type=zipfile.ZIP_DEFLATED)
zout.close(); zin.close()
PYEOF
"$ZIPALIGN" -f -p 4 "$WORK/out/unsigned.apk" "$WORK/out/aligned.apk"
"$ZIPALIGN" -c -p 4 "$WORK/out/aligned.apk"

# 签名密钥固定在本地，保证以后重打包能直接覆盖安装、不丢数据
if [ ! -f "$KEYSTORE" ]; then
  echo "  · 首次生成签名密钥：$KEYSTORE"
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 \
    -alias turbonotes -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=TurboNotes, OU=Personal, O=HaiRu, L=Yulin, ST=Shaanxi, C=CN" >/dev/null 2>&1
fi
cp "$KEYSTORE" "$WORK/turbonotes.jks"

echo "[8/8] apksigner 签名 + 验签…"
java -Xmx1024M -jar "$SIGNJAR" sign \
  --ks "$WORK/turbonotes.jks" --ks-key-alias turbonotes \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --min-sdk-version 26 \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$WORK/out/final.apk" "$WORK/out/aligned.apk"
java -jar "$SIGNJAR" verify --verbose "$WORK/out/final.apk"

cp "$WORK/out/final.apk" "$OUT"
echo
echo "============================================"
echo " 完成：$OUT"
echo " 大小：$(wc -c < "$OUT") bytes"
echo " SHA-256：$(sha256sum "$OUT" | cut -d' ' -f1)"
echo "============================================"
