# Zaparoo scanout slots

This GPL-3.0-or-later component derives from Nigel Breslaw's MagiK scanout-slot
module and the Zaparoo demo's 1080p extension. Keep its source and attribution
with this Menu fork. It is a separate kernel artifact, not linked into the
frontend. Source imports retain their original license; the Linux module
loader's license classification is separate and must not be changed to gain
access to GPL-only kernel exports.

## Compatibility policy

Initially support only the exact qualified MiSTer 6.18 kernel build. Do not
force-load a module, update the kernel, or reuse an unverified module. Unknown
and older kernels retain the ordinary fb0 frontend path. Future kernel changes
require rebuilding and requalifying the module and its memory-map contract.

Use a Zaparoo-specific module/device identity and ABI. Do not install over
`mem_wc.ko` or `mister_magik_scanout_slots.ko`, or unload someone else's module.

## Shared hardware

DreamSTer's `mem_wc` provides a generic write-combined physical-memory mapper.
MagiK's module provides bounded scanout slots. These are not interchangeable
interfaces. A loaded module is not necessarily an active renderer.

Only one Zaparoo client may own the slots at a time. Resource reservations must
last until the last mapping/file reference closes, including after process
termination. Idle module residency must not reserve another application's
memory indefinitely. Main must coordinate the frontend's FPGA bus access and
terminate its child when Main exits.

Resource reservations prevent conflicting cooperative drivers, but do not
stop arbitrary `/dev/mem` or `/dev/mem_wc` mappings or another FPGA bitstream.
Conflict detection and lifecycle handoff are required; this is not a security
boundary against another privileged process starting an unrestricted mapper.
Do not claim concurrent DreamSTer/MagiK/Zaparoo rendering is supported.

## Upstream references

- https://github.com/NigelBreslaw/MiSTer-MagiK/tree/main/mister/platform/kernel/scanout-slots
- https://github.com/skmp/minicast/tree/master/mem_wc
- https://github.com/MiSTer-devel/Linux-Kernel_MiSTer/tree/MiSTer-v6.18

## Qualified build

CI builds the module in a separate job from Quartus and uploads
`zaparoo-scanout` containing `zaparoo-scanout.zip`. It does not
install the module or change the device kernel. Only the checksum-verified
compiler archive is cached; kernel output and `Module.symvers` are built fresh.

Run the same build from the Menu repository root. Install the build packages
listed in `.github/workflows/ci_build.yml`, then:

```sh
rustup toolchain install 1.95.0 --profile minimal
bash kernel/build-scanout.sh
```

The script pins the kernel revision and verifies the GNU ARM 10.2.1 archive's
SHA-256 before extracting it. Rust 1.95.0 reproduces Kconfig's tool-detection
fields; the kernel/module build does not compile Rust. All downloaded inputs
and kernel output stay under ignored `kernel/.build/ci/`.

For local reuse, `CROSS_COMPILE` may point to Main's qualified GNU toolchain
(not the frontend's musl compiler), and `KERNEL_SRC` may point to an existing
clean checkout of the pinned revision. `BUILD_ROOT` accepts an absolute build
path, and `JOBS` controls parallelism. The full kernel build creates real
`Module.symvers`; do not suppress modpost errors or substitute
`modules_prepare` alone.

The module Makefile rejects a different source revision, tracked source edits,
config fingerprint, compiler version or missing symbol table. Do not loosen
these checks to make an unknown build pass. Expected vermagic:
`6.18.38-MiSTer SMP mod_unload ARMv7 p2v8`.

Qualification evidence:

| Input | SHA-256 |
|---|---|
| Generated `.config` | `0d010a3d551cbffcd91af7850f3f745ce73f3bb911cfd56ead902fc9b6c69823` |
| `drivers/video/fbdev/MiSTer_fb.c` | `f4044889e96a843a54bde091737825043b71b6bb8994fe3f92387cccd6ee3924` |
| `arch/arm/boot/dts/intel/socfpga/socfpga_cyclone5_de10_nano.dts` | `5c03d8ffb9e1477523d6434c5255db46433158f771fb6288320c42f8d3484938` |

ABI v1 uses `/dev/zaparoo-scanout`, ioctl `_IOR('Z', 1, layout)` and a 64-byte
layout. Slots start at `0x23000000` and `0x23400000`, outside the complete
`MiSTer_fb` DT aperture (`0x22000000`, 8 MiB). Each has 4,147,200 usable bytes
and a 4,149,248-byte mapping. Slot-one mmap selector is 8,294,400, **not its
physical address**. Only exact shared read/write mappings are accepted;
executable mappings and fork inheritance are disabled.

6.18 compatibility decisions:

- `registered_fb` is no longer exported. Validate the pinned root-level DT
  aperture instead of linking to that private symbol.
- `no_llseek` is gone; use a NULL file-operation entry.
- Published-VMA setters require GPL-only locking helpers. The pinned kernel
  invokes `.mmap` on a newly allocated VMA before insertion into the tree, so
  initialize its flags with `vm_flags_init`. Recheck this ordering for a new
  kernel; do not change the loader license marker to bypass modpost.

Successful compilation is **not hardware qualification**. Before installing
or distributing the artifact, verify the matched Main/frontend/Menu stack on
the target device, including ownership handoff, crash recovery and fb0 fallback.

## Exact-build distribution profiles

Update All's default distribution pins a reviewed Linux image; its Edge Linux
option follows the official newest image. These are moving distribution policies,
not kernel ABIs. Do not select a module from downloader settings or the image on
disk: the running kernel may still precede an update awaiting reboot.

`kernel/package-scanout.py` runs after the qualified build and writes
`kernel/.build/ci/zaparoo-scanout.zip`. Each profile is installed under
`zaparoo/modules/<kernel-release>/<GNU-kernel-build-id>/`. The profile contains
the module build ID, SHA-256, kernel revision, and Zaparoo's v1 1080p contract
identifier. The ZIP also carries kernel config/symbol-table checksums and matching
module sources with their existing attribution. Do not strip or rewrite the
module after packaging. This is integrity/provenance, not a signature.

Main reads `/sys/kernel/notes` and accepts only that exact profile; it checks the
module digest before insmod and the loaded module's GNU build ID before granting
a lease. Missing notes, missing profiles and mismatches retain fb0. Old flat
`modules/<release>/zaparoo_scanout.ko` installations no longer enable scanout.

The existing source/config/compiler pins remain in force. A locally built kernel
with the same release string as a stock image is not evidence of compatibility:
its build ID may differ. Never relabel a profile to match a different image.
Adding a pinned or Edge build requires its exact source/config/symbol inputs,
verification against the actual running image, and the hardware tests above.
Multiple tested builds with the same release string can coexist in one bundle.

After device qualification of the matched Main/Menu/frontend stack, attach
`zaparoo-scanout.zip` to that Menu release explicitly. The frontend packaging
script includes this asset only when `ZAPAROO_INCLUDE_SCANOUT=1`; a requested
missing or invalid bundle fails packaging. CI generation alone does not publish
or qualify the module. Keep older tested profiles available for users who switch
streams or have not rebooted yet. MagiK's larger Main-window mapping, diagnostics
and FPGA protocol changes are not imported by this identity-only update.
