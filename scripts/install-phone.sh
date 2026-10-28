#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo '用法: bash scripts/install-phone.sh <已配对设备名称或标识符> <自己的 Apple Development Team ID>' >&2
  exit 2
fi
device_target="$1"
development_team="$2"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$task_root/build"
if ! xcodebuild -project "$task_root/ExViewer.xcodeproj" -scheme ExViewer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$task_root/build/Phone" -allowProvisioningUpdates -jobs 2 DEVELOPMENT_TEAM="$development_team" build > "$task_root/build/phone-build.log" 2>&1; then
  rg 'error:|BUILD FAILED' "$task_root/build/phone-build.log" >&2 || true
  exit 1
fi
app_path="$task_root/build/Phone/Build/Products/Debug-iphoneos/ExViewer.app"
codesign --verify --deep --strict "$app_path"
python3 - "$app_path/embedded.mobileprovision" <<'PY'
import datetime,plistlib,subprocess,sys
result=subprocess.run(['security','cms','-D','-i',sys.argv[1]],capture_output=True,check=True)
profile=plistlib.loads(result.stdout)
expires=profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if expires<=datetime.datetime.now(datetime.timezone.utc): raise SystemExit('签名描述文件已过期。')
print('签名到期时间 UTC:', expires.isoformat())
PY
if ! xcrun devicectl device install app --device "$device_target" "$app_path"; then
  echo '安装未确认；现在只读回目标设备，不重复安装。' >&2
  xcrun devicectl device info apps --device "$device_target" --filter 'bundleIdentifier == "com.xueyj.exviewer"' || true
  exit 1
fi
xcrun devicectl device info apps --device "$device_target" --filter 'bundleIdentifier == "com.xueyj.exviewer"'
