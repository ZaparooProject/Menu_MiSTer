#!/usr/bin/env bash
# Reproduce the official stock image before building its scanout profile.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/kernel/stock-20260912.json"
build_root=${BUILD_ROOT:-"$root/kernel/.build/ci"}
mkdir -p "$build_root"
build_root=$(cd -- "$build_root" && pwd)
# Isolate stock outputs from the legacy prototype kernel/module build.
work="$build_root/stock-20260912"
mkdir -p "$work/inputs" "$work/kernel" "$work/module"
kernel_src=${KERNEL_SRC:-"$work/linux"}
kernel_build="$work/kernel"

mapfile -t inputs < <(python3 - "$manifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for key in ('kernel_revision', 'official_image_url', 'official_image_sha256',
            'build_user', 'build_host', 'build_version', 'build_timestamp',
            'kernel_config_sha256', 'kernel_symvers_sha256'):
    print(m[key])
PY
)
revision=${inputs[0]}
package=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
if [[ -z ${CROSS_COMPILE:-} ]]; then
    archive="$build_root/$package.tar.xz"
    if [[ ! -f $archive ]]; then
        curl --fail --location --retry 3 --connect-timeout 30 --max-time 1200 \
            "https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$package.tar.xz" \
            --output "$archive.partial"
        mv "$archive.partial" "$archive"
    fi
    printf '%s  %s\n' 102825ae56c9e00142d06f35d2bdd3299edb6060e84a275a25b095e66fd3fc2a "$archive" | sha256sum -c -
    tar -xJf "$archive" -C "$work"
    export CROSS_COMPILE="$work/$package/bin/arm-none-linux-gnueabihf-"
fi
test "$("${CROSS_COMPILE}gcc" -dumpfullversion -dumpversion)" = 10.2.1

official="$work/inputs/zImage_dtb"
if [[ ! -f $official ]]; then
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 600 \
        "${inputs[1]}" --output "$official.partial"
    mv "$official.partial" "$official"
fi
printf '%s  %s\n' "${inputs[2]}" "$official" | sha256sum -c -
python3 "$root/kernel/stock-scanout.py" prepare --manifest "$manifest" \
    --official "$official" --output "$work/inputs"

if [[ -z ${KERNEL_SRC:-} ]]; then
    if [[ ! -d $kernel_src ]]; then
        git init "$kernel_src"
        git -C "$kernel_src" remote add origin https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git
    fi
    if ! git -C "$kernel_src" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$kernel_src" fetch --depth=1 origin "$revision"
    fi
    if git -C "$kernel_src" rev-parse --verify HEAD >/dev/null 2>&1; then
        test -z "$(git -C "$kernel_src" status --porcelain)"
    fi
    git -C "$kernel_src" checkout --detach "$revision"
fi
kernel_src=$(cd -- "$kernel_src" && pwd)
test "$(git -C "$kernel_src" rev-parse HEAD)" = "$revision"
test -z "$(git -C "$kernel_src" status --porcelain)"
cp "$work/inputs/stock.config" "$kernel_build/.config"

# Stock's weak version.o uses the temporary banner, whereas the final strong
# version-timestamp.o contains its build number/date. Keep both explicit without
# modifying upstream source or relying on the local clock or build directory.
kernel_args=(-C "$kernel_src" "O=$kernel_build" ARCH=arm
    "CROSS_COMPILE=$CROSS_COMPILE" LOCALVERSION=-MiSTer
    RUSTC=false PAHOLE=false BINDGEN=false
    "KBUILD_BUILD_USER=${inputs[3]}" "KBUILD_BUILD_HOST=${inputs[4]}"
    "KBUILD_BUILD_VERSION=${inputs[5]}" "KBUILD_BUILD_TIMESTAMP=${inputs[6]}"
    "CFLAGS_version.o=-include $work/inputs/utsversion-tmp.h")
make "${kernel_args[@]}" olddefconfig
printf '%s  %s\n' "${inputs[7]}" "$kernel_build/.config" | sha256sum -c -
make "${kernel_args[@]}" -j"${JOBS:-$(nproc)}" vmlinux modules Image
printf '%s  %s\n' "${inputs[8]}" "$kernel_build/Module.symvers" | sha256sum -c -

cp "$root/kernel/scanout-slots/"{zaparoo_scanout.c,zaparoo_scanout_platform.h,zaparoo_scanout_uapi.h,README.md} "$work/module/"
cp "$root/kernel/stock-module.mk" "$work/module/Makefile"
python3 - "$work/module/zaparoo_scanout_platform.h" "$revision" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '#define ZAPAROO_SCANOUT_KERNEL_REVISION "aec7dc3aa4846385736f1d54c9155e3b3c726708"'
if s.count(old) != 1:
    raise SystemExit('prototype source pin changed: review stock platform contract')
p.write_text(s.replace(old, '#define ZAPAROO_SCANOUT_KERNEL_REVISION "' + sys.argv[2] + '"'))
PY
make -C "$work/module" KERNEL_SRC="$kernel_src" KERNEL_BUILD="$kernel_build" "CROSS_COMPILE=$CROSS_COMPILE"
python3 "$root/kernel/stock-scanout.py" package --manifest "$manifest" \
    --official "$official" --kernel-build "$kernel_build" --module-source "$work/module" \
    --output "$build_root/zaparoo-scanout.zip"
