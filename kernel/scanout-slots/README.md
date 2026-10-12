# Zaparoo scanout slots

This GPL-3.0-or-later component derives from Nigel Breslaw's MagiK scanout-slot
module and the Zaparoo demo's 1080p extension. Keep its source and attribution
with this Menu fork. It is a separate kernel artifact, not linked into the
frontend. The module declares `MODULE_LICENSE("GPL")`: the native vertical-sync
wait maps and requests an interrupt, and the kernel exports those helpers to
GPL modules only.

## Compatibility policy

The default build targets the official September 12, 2026 MiSTer stock image,
not a replacement kernel. Do not force-load a module, update the kernel, or reuse
an unverified module. Unknown and older kernels retain the ordinary fb0 frontend
path. Future kernel changes require rebuilding and requalifying the module and
its memory-map contract.

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

## Reproducible stock build

CI builds the module separately from Quartus and uploads `zaparoo-scanout`
containing `zaparoo-scanout.zip`. It does not install the module or change the
device kernel. Only the checksum-verified compiler archive is cached; kernel
output and `Module.symvers` are built fresh.

Run from the Menu repository root with the kernel build packages listed in
`.github/workflows/ci_build.yml`:

```sh
bash kernel/build-scanout.sh
```

The entrypoint runs the stock verification tests, then `build-stock-scanout.sh`.
`stock-20260912.json` pins the official image URL/hash, source revision, compiler,
config, symbol-table hash, build metadata, and normalized loaded Image hash.
The build downloads that exact official image and extracts its embedded config
using the standard-library Python verifier, not a locally saved device config.
It disables Rust/pahole/bindgen detection to preserve the stock Kconfig result.

The compiler archive is SHA-256 verified before extraction. The source remains
unmodified at `912aa5608a4f7be881a068c36148ca1e5abb8d20`. Stock user, host,
version, and timestamp are explicit. The weak `init/version.o` uses the original
temporary `# SMP ` banner; the final strong version object uses the stock build
number and timestamp. Neither depends on the local clock.

Packaging compares **every byte** of the reproduced ARM Image with the official
Image except the 20-byte GNU build-ID descriptor, whose note header and offset
are checked too. The normalized Image hash must match the pinned hash. Build IDs
can differ because the linked ELF includes debug/build metadata that is not in
the booted raw Image. Provenance records both IDs; the profile names the verified
stock ID. Any other byte difference, wrong config/symbol hash, or module metadata
mismatch rejects packaging. This is not permission to relabel an old module.

| Input | SHA-256 |
|---|---|
| Official `zImage_dtb` | `ab46baa275c38fb08611343836345e7aa14f153860ec09d106010436a1784bb5` |
| Embedded `.config` | `584c7fdb7884616363b38c0514266a5fc40083ae327d9a71e72deb6f3101cdab` |
| `Module.symvers` | `f58b220d8cdcb925afdd4ba4a4c0a04c02154a8f2fc658cc1fa885b89f79952f` |
| Image with GNU build-ID descriptor zeroed | `cd987213cee026bdfdfc5146f1bbb96aeda23c4e00bb754637e1fca37deb39cc` |

Expected running build ID: `ff9b30a1fb06e7bbc78274cdbf223a0131a61240`.
Expected vermagic: `6.18.38-MiSTer SMP mod_unload ARMv7 p2v8`.

Inputs/output stay under ignored `kernel/.build/ci/stock-20260912/`; the final ZIP
is `kernel/.build/ci/zaparoo-scanout.zip`. `BUILD_ROOT` overrides the build root,
`JOBS` controls parallelism, `KERNEL_SRC` accepts a clean checkout at the exact
revision, and `CROSS_COMPILE` accepts a trusted GNU ARM 10.2.1 toolchain (not the
frontend's musl compiler). The generated module directory contains matching
source, stock revision header, and strict `stock-module.mk` as its Makefile.
The original prototype source/header/Makefile pins remain unchanged.

For archival prototype reproduction only, use `bash kernel/build-prototype-scanout.sh`
with Rust 1.95.0 installed and a separate `BUILD_ROOT`. That retains the older
`aec7dc3` source and `0d010a3d...` config contract; its profile is not the stock
profile. Never suppress modpost errors or substitute `modules_prepare` for the
full build that creates genuine symbol exports.

ABI v2 uses `/dev/zaparoo-scanout`, ioctl `_IOR('Z', 1, layout)` and a 64-byte
layout. Slots start at `0x23000000` and `0x23400000`, outside the complete
`MiSTer_fb` DT aperture (`0x22000000`, 8 MiB). Each has 4,147,200 usable bytes
and a 4,149,248-byte mapping. Slot-one mmap selector is 8,294,400, **not its
physical address**. Only exact shared read/write mappings are accepted;
executable mappings and fork inheritance are disabled.

v2 adds Menu's native video window (`0x3A000000`, 3 MiB, the DDR contract in
`rtl/native_video_reader.sv`) as two more exact-length mappings whose selectors
and sizes the layout reports: the 4 KiB control page, uncached, and the
3,137,536 bytes of frame slots after it, write-combined. The control words stay
uncached so a publish can never wait in a write-combining buffer behind the
pixels it announces. The window is reserved by its first mapping, not at open,
so an HDMI-only client never claims it.

`_IOR('Z', 2, __u32)` blocks until the native raster's next vertical sync and
returns a running count, or fails with `ETIMEDOUT` after 50 ms. The source is
`sys_top`'s `video_sync` pulse on `f2h_irq[1]` (GIC SPI 41), beside the HDMI
interrupt `MiSTer_fb` owns on SPI 40. The stock device tree has no node for it,
so the module maps it on `MiSTer_fb`'s interrupt controller itself. The
interrupt is requested by the first wait and freed with the last file
reference; idle residency holds no interrupt.

6.18 compatibility decisions:

- `registered_fb` is no longer exported. Validate the pinned root-level DT
  aperture instead of linking to that private symbol.
- `no_llseek` is gone; use a NULL file-operation entry.
- The pinned kernel invokes `.mmap` on a newly allocated VMA before insertion
  into the tree, so initialize its flags with `vm_flags_init`. Recheck this
  ordering for a new kernel.

Successful compilation is **not hardware qualification**. Before installing
or distributing the artifact, verify the matched Main/frontend/Menu stack on
the target device, including ownership handoff, crash recovery and fb0 fallback.

## Exact-build distribution profiles

Update All's default distribution pins a reviewed Linux image; its Edge Linux
option follows the official newest image. These are moving distribution policies,
not kernel ABIs. Do not select a module from downloader settings or the image on
disk: the running kernel may still precede an update awaiting reboot.

`kernel/stock-scanout.py package` runs after stock reproduction and writes
`kernel/.build/ci/zaparoo-scanout.zip` (`package-scanout.py` remains the prototype
packager). Each profile is installed under
`zaparoo/modules/<kernel-release>/<GNU-kernel-build-id>/`. The profile contains
the module build ID, SHA-256, kernel revision, and Zaparoo's v2 native contract
identifier. The ZIP also carries kernel config/symbol-table checksums and matching
module sources with their existing attribution. Do not strip or rewrite the
module after packaging. This is integrity/provenance, not a signature.

Main reads `/sys/kernel/notes` and accepts only that exact profile; it checks the
module digest before insmod and the loaded module's GNU build ID before granting
a lease. Missing notes, missing profiles and mismatches retain fb0. Old flat
`modules/<release>/zaparoo_scanout.ko` installations no longer enable scanout.

A locally built kernel with the same release string as a stock image is not
evidence of compatibility. The stock path permits an identity difference only
after the full Image comparison above. Adding another pinned or Edge build needs
its own exact source/config/symbol inputs, official-image verification, and the
hardware tests above. Multiple tested builds with the same release string can
coexist in one bundle.

At September 2026 qualification, Update All pinned and Edge manifests both
selected this September 12 stock image. That observation is not a permanent
channel guarantee: recheck manifests before releasing, and add separate profiles
when they diverge. The prior stock-target module passed cold loading and frontend
crash/relaunch with accelerated scanout on the matched Main/Menu/frontend stack.
Those observations do not automatically qualify each new module artifact or
replace physical output, ownership-handoff, and fallback checks. New bundles keep
an explicit qualification-required provenance marker until release validation.

After device qualification of the matched Main/Menu/frontend stack, attach
`zaparoo-scanout.zip` to that Menu release explicitly. The frontend packaging
script includes this asset only when `ZAPAROO_INCLUDE_SCANOUT=1`; a requested
missing or invalid bundle fails packaging. CI generation alone does not publish
or qualify the module. Keep older tested profiles available for users who switch
streams or have not rebooted yet. MagiK's larger Main-window mapping, diagnostics
and FPGA protocol changes are not imported by this identity-only update.
