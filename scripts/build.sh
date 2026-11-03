#!/bin/sh
# Construit build/Brasseur.app ; avec « install », le copie dans ~/Applications et le relance.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Brasseur.app
ICON=build/AppIcon.icns
if [ ! -f "$ICON" ]; then
    rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o "$ICON"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Brasseur" "$APP/Contents/MacOS/Brasseur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Langues déclarées : macOS choisit selon la langue du système (les textes sont dans Localization.swift).
for lang in en fr; do mkdir -p "$APP/Contents/Resources/$lang.lproj" && : > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"; done
codesign --force --sign - "$APP"
echo "Construit : $APP"

if [ "${1:-}" = "install" ]; then
    DEST="$HOME/Applications/Brasseur.app"
    pkill -x Brasseur 2>/dev/null && sleep 1 || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installé et lancé : $DEST"
fi
