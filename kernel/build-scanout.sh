#!/usr/bin/env bash
# Build the exact kernel/module pair accepted by scanout-slots/Makefile.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${BUILD_ROOT:-"$root/kernel/.build/ci"}
kernel_src=${KERNEL_SRC:-"$build_root/linux"}
kernel_build="$build_root/kernel"
revision=aec7dc3aa4846385736f1d54c9155e3b3c726708
package=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
mkdir -p "$build_root"

if [[ -z ${CROSS_COMPILE:-} ]]; then
    archive="$build_root/$package.tar.xz"
    if [[ ! -f $archive ]]; then
        curl --fail --location --retry 3 --connect-timeout 30 --max-time 1200 \
            "https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$package.tar.xz" \
            --output "$archive.partial"
        mv "$archive.partial" "$archive"
    fi
    # SHA-256: https://github.com/buildroot/buildroot/blob/2021.02/toolchain/toolchain-external/toolchain-external-arm-arm/toolchain-external-arm-arm.hash
    printf '%s  %s\n' 102825ae56c9e00142d06f35d2bdd3299edb6060e84a275a25b095e66fd3fc2a "$archive" | sha256sum -c -
    tar -xJf "$archive" -C "$build_root"
    export CROSS_COMPILE="$build_root/$package/bin/arm-none-linux-gnueabihf-"
fi

test "$("${CROSS_COMPILE}gcc" -dumpfullversion -dumpversion)" = 10.2.1
if [[ -z ${KERNEL_SRC:-} ]]; then
    if [[ ! -d $kernel_src ]]; then
        git init "$kernel_src"
        git -C "$kernel_src" remote add origin https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git
    fi
    if ! git -C "$kernel_src" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$kernel_src" fetch --depth=1 origin "$revision"
    fi
    if git -C "$kernel_src" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$kernel_src" diff --quiet HEAD -- .
    fi
    git -C "$kernel_src" checkout --detach "$revision"
fi
# Explicit source overrides are read-only inputs, never reset or checked out.
test "$(git -C "$kernel_src" rev-parse HEAD)" = "$revision"
git -C "$kernel_src" diff --quiet HEAD -- .

# Pin optional tool detection as well as the target compiler. Rust 1.95.0 is
# needed only to reproduce the qualified Kconfig fingerprint; no Rust is built.
export RUSTUP_TOOLCHAIN=1.95.0
rustc --version | grep -E '^rustc 1\.95\.0 '
export PAHOLE=false
export BINDGEN=false
kernel_args=(-C "$kernel_src" "O=$kernel_build" ARCH=arm
    "CROSS_COMPILE=$CROSS_COMPILE" LOCALVERSION=-MiSTer)
make "${kernel_args[@]}" MiSTer_defconfig
printf '%s  %s\n' 0d010a3d551cbffcd91af7850f3f745ce73f3bb911cfd56ead902fc9b6c69823 "$kernel_build/.config" | sha256sum -c -
# modules_prepare alone cannot supply a genuine Module.symvers.
make "${kernel_args[@]}" -j"${JOBS:-$(nproc)}" vmlinux modules
make -C "$root/kernel/scanout-slots" KERNEL_SRC="$kernel_src" KERNEL_BUILD="$kernel_build" CROSS_COMPILE="$CROSS_COMPILE"
vermagic=$(modinfo -F vermagic "$root/kernel/scanout-slots/zaparoo_scanout.ko")
test "${vermagic% }" = '6.18.38-MiSTer SMP mod_unload ARMv7 p2v8'
sha256sum "$root/kernel/scanout-slots/zaparoo_scanout.ko"
