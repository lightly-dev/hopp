#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f VERSION ]]; then
    echo "VERSION is missing" >&2
    exit 1
fi
version="$(<VERSION)"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "VERSION must contain a stable x.y.z version: $version" >&2
    exit 2
fi

app="$PWD/dist/Hopp.app"
binary="$app/Contents/MacOS/Hopp"
if [[ ! -d "$app" || ! -f "$binary" ]]; then
    echo "Built app is missing: $app" >&2
    exit 1
fi
app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
if [[ "$app_version" != "$version" ]]; then
    echo "App version $app_version does not match VERSION $version" >&2
    exit 1
fi
codesign --verify --strict "$app"

archs="$(lipo -archs "$binary")"
case " $archs " in
    " arm64 ") artifact_arch="arm64" ;;
    " x86_64 ") artifact_arch="x86_64" ;;
    " arm64 x86_64 "|" x86_64 arm64 ") artifact_arch="universal" ;;
    *)
        echo "Unsupported app architectures: $archs" >&2
        exit 1
        ;;
esac

background_1x="$PWD/assets/dmg-background.png"
background_2x="$PWD/assets/dmg-background@2x.png"
for image in "$background_1x" "$background_2x"; do
    if [[ ! -f "$image" ]]; then
        echo "DMG background is missing: $image (run: swift scripts/make-dmg-background.swift)" >&2
        exit 1
    fi
done

# Window geometry. The background images are drawn for exactly these values;
# keep them in sync with scripts/make-dmg-background.swift.
window_width=600
window_height=380
icon_size=128
app_position="150, 180"
applications_position="450, 180"

volume_name="Hopp $version"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hopp-dmg.XXXXXX")"
mount_dir="$work_dir/mount"
cleanup() {
    if [[ -d "$mount_dir" ]] && mount | grep -q " on $mount_dir "; then
        hdiutil detach "$mount_dir" -force -quiet || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

staging_dir="$work_dir/staging"
writable_dmg="$work_dir/Hopp-rw.dmg"
temporary_dmg="$work_dir/Hopp.dmg"
mkdir -p "$staging_dir/.background" "$mount_dir"
ditto "$app" "$staging_dir/Hopp.app"
ln -s /Applications "$staging_dir/Applications"
# One multi-resolution TIFF so Finder picks the @2x art on Retina displays.
tiffutil -cathidpicheck "$background_1x" "$background_2x" \
    -out "$staging_dir/.background/background.tiff" >/dev/null

# Build a writable image with headroom for Finder's .DS_Store, lay it out,
# then compress it. Progress goes to stderr: the last stdout line is the path.
hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -fs HFS+ \
    -format UDRW \
    -size "$(( $(du -sm "$staging_dir" | cut -f1) + 20 ))m" \
    "$writable_dmg" >&2
hdiutil attach "$writable_dmg" \
    -readwrite -noverify -noautoopen -nobrowse \
    -mountpoint "$mount_dir" >&2

SetFile -a V "$mount_dir/.background"

# The mount is -nobrowse (no Desktop icon or sidebar entry while building), so
# Finder is pointed at it by POSIX path rather than by disk name.
layout_script="
set dmgRoot to POSIX file \"$mount_dir\" as alias
tell application \"Finder\"
    open dmgRoot
    set dmgWindow to container window of dmgRoot
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    try
        set sidebar width of dmgWindow to 0
    end try
    set bounds of dmgWindow to {200, 120, $(( 200 + window_width )), $(( 120 + window_height ))}
    set viewOptions to icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $icon_size
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to file \".background:background.tiff\" of dmgRoot
    set position of item \"Hopp.app\" of dmgRoot to {$app_position}
    set position of item \"Applications\" of dmgRoot to {$applications_position}
    close dmgWindow
    open dmgRoot
    delay 1
    set bounds of container window of dmgRoot to {200, 120, $(( 200 + window_width )), $(( 120 + window_height ))}
    update dmgRoot without registering applications
    delay 1
    close container window of dmgRoot
end tell
"
layout_ok=1
for attempt in 1 2 3; do
    if osascript -e "$layout_script" >&2; then
        layout_ok=1
        break
    fi
    layout_ok=0
    echo "Finder layout attempt $attempt failed" >&2
    sleep 2
done
if [[ "$layout_ok" != 1 ]]; then
    if [[ "${HOPP_DMG_REQUIRE_LAYOUT:-0}" == 1 ]]; then
        echo "Finder could not lay out the DMG window" >&2
        exit 1
    fi
    # Still a working installer, just without the arranged window.
    echo "::warning::Finder could not lay out the DMG window; shipping the default layout" >&2
fi

# Wait for Finder to flush .DS_Store before detaching.
for _ in {1..10}; do
    [[ -f "$mount_dir/.DS_Store" || "$layout_ok" != 1 ]] && break
    sleep 1
done
# Added after the layout: hdiutil -srcfolder drops .VolumeIcon.icns and
# Finder deletes it while laying out the window.
if [[ -f assets/AppIcon.icns ]]; then
    cp assets/AppIcon.icns "$mount_dir/.VolumeIcon.icns"
    SetFile -a C "$mount_dir"
    SetFile -a V "$mount_dir/.VolumeIcon.icns"
fi
rm -rf "$mount_dir/.fseventsd" "$mount_dir/.Trashes"
chmod -Rf go-w "$mount_dir" || true
bless --folder "$mount_dir" >&2 2>/dev/null || true
sync
hdiutil detach "$mount_dir" -quiet || {
    sleep 2
    hdiutil detach "$mount_dir" -force -quiet
}

hdiutil convert "$writable_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$temporary_dmg" >&2
hdiutil verify "$temporary_dmg" >&2

output="$PWD/dist/Hopp-${version}-${artifact_arch}.dmg"
mv -f "$temporary_dmg" "$output"
echo "$output"
