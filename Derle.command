#!/bin/bash
cd "$(dirname "$0")"
set -e
APP="RobotSupurge.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift derleyicisi bulunamadı. Xcode'u kurun veya Terminal'de şunu çalıştırın:  xcode-select --install"
  read -p "Kapatmak için Enter'a basın"; exit 1
fi

echo "Derleniyor..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O Sources/*.swift -o "$APP/Contents/MacOS/RobotSupurge"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
xattr -cr "$APP" || true

echo "Hazır! Uygulama başlatılıyor..."
open "$APP"
echo "Menü çubuğundaki ✨ ikonundan veya ekranın üstündeki robota tıklayarak temizleyebilirsiniz."
sleep 3
