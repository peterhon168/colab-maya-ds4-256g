#!/usr/bin/env bash
set -euo pipefail

export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_BUNDLE_NAME="MayaStudio"
EXEC_NAME="MayaStudio"
BUNDLE_ID="io.github.maya.strata.studio"
DISPLAY_NAME="Maya · Strata Studio"
APP_VERSION="1.0.0"

if [ -f "${PROJECT_ROOT}/VERSION" ]; then
    APP_VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION")"
    APP_VERSION="${APP_VERSION:-1.0.0}"
fi

MAKE_ZIP=0
OUT_DIR="${PROJECT_ROOT}"
while [ $# -gt 0 ]; do
    case "$1" in
        --zip)
            MAKE_ZIP=1
            shift
            ;;
        --out)
            OUT_DIR="${2:?Missing directory after --out}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash macos_app/build_macos_app.sh [--out <dir>] [--zip]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
BUNDLE_DIR="${OUT_DIR}/${APP_BUNDLE_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "[build] Building ${BUNDLE_DIR} (v${APP_VERSION})..."

# 1. Copy clean, non-secret source & runtime assets into Contents/Resources/
#    Strictly excludes ~/.config/maya-gcs, gcs-key.json, hf-token, gcs-bucket, *.key, *.pem, .env*, etc.
python3 - "${PROJECT_ROOT}" "${RESOURCES_DIR}" << 'PY'
import fnmatch
import os
import shutil
import sys
from pathlib import Path

src_root = Path(sys.argv[1])
res_root = Path(sys.argv[2])

FORBIDDEN_EXACT = {
    "gcs-key.json",
    "gcs-bucket",
    "hf-token",
    ".env",
    ".DS_Store",
    "__MACOSX",
    "__pycache__",
}

FORBIDDEN_GLOBS = (
    "*.key",
    "*.pem",
    "*secret*",
    "*credential*",
    ".env.*",
    "._*",
    "*.pyc",
    "*.pyo",
    "*.tmp",
    "*.swp",
    "*.log",
)

ALLOW_EXACT = {
    "audit_secrets.py",
}

def is_excluded(name: str) -> bool:
    if name in ALLOW_EXACT or name.endswith(".example"):
        return False
    if name in FORBIDDEN_EXACT:
        return True
    low = name.lower()
    return any(fnmatch.fnmatch(low, pat.lower()) for pat in FORBIDDEN_GLOBS)

def copy_clean_tree(rel_dir: str) -> int:
    src_dir = src_root / rel_dir
    if not src_dir.is_dir():
        return 0
    count = 0
    for dp, dns, fns in os.walk(src_dir):
        dns[:] = [d for d in sorted(dns) if not is_excluded(d)]
        rel_sub = Path(dp).relative_to(src_root)
        dst_dir = res_root / rel_sub
        dst_dir.mkdir(parents=True, exist_ok=True)
        for fn in sorted(fns):
            if is_excluded(fn):
                continue
            src_file = Path(dp) / fn
            dst_file = dst_dir / fn
            shutil.copy2(src_file, dst_file)
            count += 1
    return count

for folder in ("studio", "scripts", "src", "resources"):
    copied = copy_clean_tree(folder)
    if folder == "studio" and copied == 0:
        print("[build] Warning: studio/ directory not found or empty; skipped embedding studio/")
    else:
        print(f"[build] Embedded {folder}/ ({copied} clean files)")

for top_doc in ("LICENSE", "README.md", "SKILL.md"):
    p = src_root / top_doc
    if p.is_file():
        shutil.copy2(p, res_root / top_doc)
PY

if [ -d "${RESOURCES_DIR}/scripts" ]; then
    chmod +x "${RESOURCES_DIR}/scripts/"*.sh 2>/dev/null || true
fi

# Double-check zero secret files exist inside the bundle
for forbidden in "gcs-key.json" "gcs-bucket" "hf-token" ".env"; do
    if find "${BUNDLE_DIR}" -name "${forbidden}" -print -quit | grep -q .; then
        echo "[build] ERROR: Forbidden credential file '${forbidden}' detected inside ${BUNDLE_DIR}!" >&2
        exit 1
    fi
done
if find "${BUNDLE_DIR}" \( -name "*.key" -o -name "*.pem" \) -print -quit | grep -q .; then
    echo "[build] ERROR: Forbidden private key (*.key/*.pem) detected inside ${BUNDLE_DIR}!" >&2
    exit 1
fi

# 2. Generate Contents/Info.plist (ATS allows 127.0.0.1 / localhost HTTP)
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>127.0.0.1</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
            <key>localhost</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
                <key>NSIncludesSubdomains</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
EOF

# 3. Render dark AI compute workbench vector icon (AppIcon.icns) via CoreGraphics + iconutil
ICONSET_DIR="${TMP_WORK}/MayaStudio.iconset"
mkdir -p "${ICONSET_DIR}"

swift - "${ICONSET_DIR}" << 'SWIFT_ICON'
import AppKit
import CoreGraphics
import Foundation

let iconsetDir = CommandLine.arguments[1]

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a).cgColor
}

func drawStrataPlane(in c: CGContext, centerY: CGFloat, halfW: CGFloat, halfH: CGFloat,
                     fillTop: CGColor, fillBottom: CGColor, stroke: CGColor, lineWidth: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: centerY + halfH))
    p.addLine(to: CGPoint(x: 512 + halfW, y: centerY))
    p.addLine(to: CGPoint(x: 512, y: centerY - halfH))
    p.addLine(to: CGPoint(x: 512 - halfW, y: centerY))
    p.closeSubpath()

    c.saveGState()
    c.addPath(p)
    c.clip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [fillTop, fillBottom] as CFArray,
        locations: [0, 1]
    )!
    c.drawLinearGradient(
        grad,
        start: CGPoint(x: 512 - halfW, y: centerY + halfH),
        end: CGPoint(x: 512 + halfW, y: centerY - halfH),
        options: []
    )
    c.restoreGState()

    c.saveGState()
    c.addPath(p)
    c.setStrokeColor(stroke)
    c.setLineWidth(lineWidth)
    c.setLineJoin(.round)
    c.strokePath()
    c.restoreGState()
}

func drawIcon(_ size: Int, _ path: String) {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let c = NSGraphicsContext.current!.cgContext
    c.scaleBy(x: s / 1024.0, y: s / 1024.0)
    c.setAllowsAntialiasing(true)

    // Outer squircle tile (#0B0F17 -> #131E33)
    let tile = CGRect(x: 84, y: 84, width: 856, height: 856)
    let shape = CGPath(roundedRect: tile, cornerWidth: 205, cornerHeight: 205, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgba(0, 0, 0, 0.48))
    c.addPath(shape)
    c.setFillColor(rgba(11, 15, 23))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()

    let bgGrad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgba(11, 15, 23), rgba(17, 25, 42), rgba(21, 35, 64)] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    c.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 140, y: 90),
        end: CGPoint(x: 880, y: 940),
        options: []
    )

    // Ambient cobalt + emerald telemetry glow behind strata planes
    let cobaltGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgba(37, 99, 235, 0.34), rgba(37, 99, 235, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    c.drawRadialGradient(
        cobaltGlow,
        startCenter: CGPoint(x: 512, y: 540),
        startRadius: 20,
        endCenter: CGPoint(x: 512, y: 540),
        endRadius: 380,
        options: []
    )

    let emeraldGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgba(16, 185, 129, 0.24), rgba(16, 185, 129, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    c.drawRadialGradient(
        emeraldGlow,
        startCenter: CGPoint(x: 512, y: 690),
        startRadius: 10,
        endCenter: CGPoint(x: 512, y: 690),
        endRadius: 260,
        options: []
    )

    // Subtle precision coordinate grid lines
    c.saveGState()
    c.setStrokeColor(rgba(148, 163, 184, 0.06))
    c.setLineWidth(2)
    for step in stride(from: 200, through: 824, by: 78) {
        let p = CGFloat(step)
        c.move(to: CGPoint(x: p, y: 84)); c.addLine(to: CGPoint(x: p, y: 940))
        c.move(to: CGPoint(x: 84, y: p)); c.addLine(to: CGPoint(x: 940, y: p))
    }
    c.strokePath()
    c.restoreGState()
    c.restoreGState()

    // Crisp slate rim border
    c.saveGState()
    c.addPath(shape)
    c.setStrokeColor(rgba(148, 163, 184, 0.24))
    c.setLineWidth(4)
    c.strokePath()
    c.restoreGState()

    // Stacked Strata compute layers (3 isometric planes representing VRAM / RAM / NVMe-CDN)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: rgba(0, 0, 0, 0.45))
    drawStrataPlane(
        in: c,
        centerY: 360,
        halfW: 268,
        halfH: 112,
        fillTop: rgba(30, 41, 59, 0.96),
        fillBottom: rgba(15, 23, 42, 0.96),
        stroke: rgba(100, 116, 139, 0.65),
        lineWidth: 6
    )
    drawStrataPlane(
        in: c,
        centerY: 472,
        halfW: 268,
        halfH: 112,
        fillTop: rgba(30, 64, 175, 0.94),
        fillBottom: rgba(23, 37, 84, 0.96),
        stroke: rgba(96, 165, 250, 0.80),
        lineWidth: 6
    )
    drawStrataPlane(
        in: c,
        centerY: 584,
        halfW: 268,
        halfH: 112,
        fillTop: rgba(56, 189, 248, 0.92),
        fillBottom: rgba(37, 99, 235, 0.95),
        stroke: rgba(186, 230, 253, 0.95),
        lineWidth: 7
    )
    c.restoreGState()

    // Luminous "M" neural bridge & emerald anchor node on top plane
    let bridgeNodes = [
        CGPoint(x: 376, y: 556),
        CGPoint(x: 444, y: 634),
        CGPoint(x: 512, y: 564),
        CGPoint(x: 580, y: 634),
        CGPoint(x: 648, y: 556),
    ]
    c.saveGState()
    c.setShadow(offset: .zero, blur: 18, color: rgba(16, 185, 129, 0.65))
    c.setStrokeColor(rgba(255, 255, 255, 0.95))
    c.setLineWidth(20)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: bridgeNodes[0])
    for pt in bridgeNodes.dropFirst() {
        c.addLine(to: pt)
    }
    c.strokePath()
    c.restoreGState()

    for (idx, pt) in bridgeNodes.enumerated() {
        let radius: CGFloat = (idx == 2) ? 26 : 19
        let fill = (idx == 2) ? rgba(16, 185, 129) : rgba(248, 250, 252)
        c.saveGState()
        c.setFillColor(fill)
        c.fillEllipse(in: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2))
        c.setStrokeColor(rgba(11, 15, 23, 0.9))
        c.setLineWidth(5)
        c.strokeEllipse(in: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2))
        c.restoreGState()
    }

    // Top telemetry status pill dot (emerald live indicator)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 16, color: rgba(16, 185, 129, 0.85))
    c.setFillColor(rgba(16, 185, 129))
    c.fillEllipse(in: CGRect(x: 758, y: 760, width: 44, height: 44))
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for size in [16, 32, 128, 256, 512] {
    drawIcon(size, "\(iconsetDir)/icon_\(size)x\(size).png")
    drawIcon(size * 2, "\(iconsetDir)/icon_\(size)x\(size)@2x.png")
}
SWIFT_ICON

iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

# 4. Compile native AppKit + WebKit executable (Universal arm64 + x86_64 if cross-target succeeds)
echo "[build] Compiling ${SCRIPT_DIR}/MayaStudioApp.swift (macOS 13.0+)..."
HOST_ARCH="$(uname -m)"

if swiftc -O \
    -target arm64-apple-macos13.0 \
    -parse-as-library \
    -framework AppKit \
    -framework WebKit \
    "${SCRIPT_DIR}/MayaStudioApp.swift" \
    -o "${MACOS_DIR}/${EXEC_NAME}_arm64" 2>"${TMP_WORK}/arm64.err"; then
    if swiftc -O \
        -target x86_64-apple-macos13.0 \
        -parse-as-library \
        -framework AppKit \
        -framework WebKit \
        "${SCRIPT_DIR}/MayaStudioApp.swift" \
        -o "${MACOS_DIR}/${EXEC_NAME}_x86_64" 2>/dev/null; then
        lipo -create -output "${MACOS_DIR}/${EXEC_NAME}" \
            "${MACOS_DIR}/${EXEC_NAME}_arm64" \
            "${MACOS_DIR}/${EXEC_NAME}_x86_64"
        rm -f "${MACOS_DIR}/${EXEC_NAME}_arm64" "${MACOS_DIR}/${EXEC_NAME}_x86_64"
        echo "[build] Compiled Universal Binary (arm64 + x86_64, minOS 13.0)"
    else
        mv -f "${MACOS_DIR}/${EXEC_NAME}_arm64" "${MACOS_DIR}/${EXEC_NAME}"
        echo "[build] Compiled arm64 Binary (minOS 13.0)"
    fi
else
    cat "${TMP_WORK}/arm64.err" >&2
    rm -f "${MACOS_DIR}/${EXEC_NAME}_arm64"
    echo "[build] Retrying with host architecture (${HOST_ARCH})..."
    swiftc -O \
        -target "${HOST_ARCH}-apple-macos13.0" \
        -parse-as-library \
        -framework AppKit \
        -framework WebKit \
        "${SCRIPT_DIR}/MayaStudioApp.swift" \
        -o "${MACOS_DIR}/${EXEC_NAME}"
    echo "[build] Compiled ${HOST_ARCH} Binary (minOS 13.0)"
fi

chmod +x "${MACOS_DIR}/${EXEC_NAME}"

# 5. Strip extended attributes, ad-hoc sign, and strictly verify signature
xattr -cr "${BUNDLE_DIR}" 2>/dev/null || true
codesign --force --deep --sign - "${BUNDLE_DIR}"
codesign --verify --deep --strict "${BUNDLE_DIR}"
touch "${BUNDLE_DIR}"

echo "✅ Built and signed: ${BUNDLE_DIR}"

if [ "${MAKE_ZIP}" -eq 1 ]; then
    ZIP_PATH="${OUT_DIR}/${APP_BUNDLE_NAME}-macOS.zip"
    rm -f "${ZIP_PATH}"
    ditto -c -k --sequesterRsrc --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"
    echo "✅ Packaged archive: ${ZIP_PATH}"
fi
