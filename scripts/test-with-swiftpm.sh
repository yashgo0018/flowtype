#!/bin/bash
# Compile/test the same Swift sources when xcodebuild's IDE plug-ins cannot load.
# This does not validate signing, .app resources, TCC, App Intents discovery or distribution.
set -euo pipefail
flowtype_root="$(cd "$(dirname "$0")/.." && pwd)"
flowtype_validation="$(mktemp -d "${TMPDIR:-/tmp/}flowtype-validation.XXXXXX")"
trap 'rm -rf "$flowtype_validation"' EXIT
mkdir -p "$flowtype_validation/Sources/Flowtype" "$flowtype_validation/Tests/FlowtypeTests"
python3 - "$flowtype_root" "$flowtype_validation" <<'PY'
import glob, json, os, sys
root, temporary = sys.argv[1:]
lock = os.path.join(root, 'Flowtype.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
pins = {p['identity']: p['state']['version'] for p in json.load(open(lock))['pins']}
manifest = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Flowtype", platforms: [.macOS(.v14)], products: [.executable(name: "Flowtype", targets: ["Flowtype"])], dependencies: [
.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "%s"),
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "%s")
], targets: [.executableTarget(name: "Flowtype", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift"), .product(name: "Sparkle", package: "Sparkle")]), .testTarget(name: "FlowtypeTests", dependencies: ["Flowtype"])])
''' % (pins['argmax-oss-swift'], pins['sparkle'])
open(os.path.join(temporary, 'Package.swift'), 'w').write(manifest)
for directory, destination in [('Flowtype', 'Sources/Flowtype'), ('FlowtypeTests', 'Tests/FlowtypeTests')]:
    for source in glob.glob(os.path.join(root, directory, '*.swift')):
        os.symlink(source, os.path.join(temporary, destination, os.path.basename(source)))
import shutil
shutil.copyfile(lock, os.path.join(temporary, 'Package.resolved'))
PY
export CLANG_MODULE_CACHE_PATH="$flowtype_validation/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$flowtype_validation/module-cache"
swift test --package-path "$flowtype_validation" --cache-path "$flowtype_validation/cache" \
    --config-path "$flowtype_validation/config" --security-path "$flowtype_validation/security" \
    --disable-sandbox --disable-keychain "$@"
