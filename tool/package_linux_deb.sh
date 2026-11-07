#!/bin/sh
# Package the pi-desktop Linux runner and its pinned PI + Node runtime.
set -eu
case "${1:-}" in
  "") ;;
  *) printf '%s\n' "Unknown argument: $1" >&2; exit 1 ;;
esac
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version:[[:space:]]*//p' "$root/pubspec.yaml")
marketing=${version%%+*}
case "$(uname -m)" in
  x86_64) arch=x64; package_arch=amd64 ;;
  aarch64 | arm64) arch=arm64; package_arch=arm64 ;;
  *) printf '%s\n' "Unsupported processor: $(uname -m)" >&2; exit 1 ;;
esac
bundle="$root/build/linux/$arch/release/bundle"
if [ ! -x "$bundle/pi-desktop" ]; then
  printf '%s\n' "No bundle at $bundle. Run: flutter build linux --release" >&2
  exit 1
fi
if [ ! -f "$bundle/data/pi-runtime/node" ]; then
  dart run "$root/tool/bundle_pi_runtime.dart" --target "$bundle/data/pi-runtime" --platform linux --arch "$arch"
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/opt/pi-desktop" "$stage/usr/bin" "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/128x128/apps" "$stage/DEBIAN"
cp -a "$bundle/." "$stage/opt/pi-desktop/"
cp "$root/assets/branding/app_icon.png" "$stage/usr/share/icons/hicolor/128x128/apps/pi-desktop.png"
cat > "$stage/usr/bin/pi-desktop" << 'EOF'
#!/bin/sh
exec /opt/pi-desktop/pi-desktop "$@"
EOF
chmod 755 "$stage/usr/bin/pi-desktop"
cat > "$stage/usr/share/applications/pi-desktop.desktop" << 'EOF'
[Desktop Entry]
Name=pi-desktop
Comment=Desktop workspace for the Pi coding agent
Exec=pi-desktop %U
Icon=pi-desktop
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=dev.pi.desktop
MimeType=x-scheme-handler/pi-desktop;
EOF
cat > "$stage/DEBIAN/control" << EOF
Package: pi-desktop
Version: ${marketing}
Section: devel
Priority: optional
Architecture: ${package_arch}
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: pi-desktop
Description: Desktop workspace for the Pi coding agent
 A Flutter desktop app with streaming conversations and an integrated IDE.
EOF
out="$root/build/installers"
mkdir -p "$out"
name="pi-desktop-${marketing}-linux-${package_arch}"
dpkg-deb --build --root-owner-group "$stage" "$out/$name.deb"
tar -C "$bundle" -czf "$out/$name.tar.gz" .
printf 'Wrote %s\n' "$out/$name.deb" "$out/$name.tar.gz"
