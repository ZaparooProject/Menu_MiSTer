/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 Nigel Breslaw
 * Zaparoo fork: separate device identity and exclusive mapping ownership.
 */
#ifndef ZAPAROO_SCANOUT_UAPI_H
#define ZAPAROO_SCANOUT_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ZAPAROO_SCANOUT_ABI_VERSION 2U
#define ZAPAROO_SCANOUT_SLOT_COUNT 2U
#define ZAPAROO_SCANOUT_WRITE_COMBINE 0x00000001U
#define ZAPAROO_SCANOUT_EXCLUSIVE_OWNER 0x00000002U
#define ZAPAROO_SCANOUT_NATIVE_WINDOW 0x00000004U
#define ZAPAROO_SCANOUT_NATIVE_VBLANK 0x00000008U

struct zaparoo_scanout_slot {
	__u32 physical_address;
	__u32 mmap_offset_bytes;
};

struct zaparoo_scanout_layout {
	__u32 abi_version;
	__u32 slot_count;
	__u32 max_width;
	__u32 max_height;
	__u32 max_stride_bytes;
	__u32 slot_capacity_bytes;
	__u32 map_bytes;
	__u32 flags;
	struct zaparoo_scanout_slot slots[ZAPAROO_SCANOUT_SLOT_COUNT];
	/* Native video DDR window: one uncached control page, then the
	 * write-combined frame slots. Each is its own exact-length mapping.
	 */
	__u32 native_control_offset_bytes;
	__u32 native_control_bytes;
	__u32 native_pixels_offset_bytes;
	__u32 native_pixels_bytes;
};

/* Distinct ioctl namespace: a MagiK device must not pass this handshake. */
#define ZAPAROO_SCANOUT_GET_LAYOUT _IOR('Z', 0x01, struct zaparoo_scanout_layout)
/* Blocks until the native raster's next vertical sync and returns its running
 * count. Fails with ETIMEDOUT when no sync arrives within 50 ms.
 */
#define ZAPAROO_SCANOUT_WAIT_NATIVE_VBLANK _IOR('Z', 0x02, __u32)
#endif
