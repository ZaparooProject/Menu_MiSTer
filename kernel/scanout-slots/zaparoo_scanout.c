// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Breslaw
// Zaparoo fork: namespaced device, 6.18 platform validation, lifetime ownership.

/* Bounded write-combined RGB565 slots. No FPGA commands, DMA, or IRQ ownership.
 * Reservations belong to the open file and all its VMAs, not module residency.
 */
#include <linux/build_bug.h>
#include <linux/capability.h>
#include <linux/fs.h>
#include <linux/ioport.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <generated/utsrelease.h>
#include "zaparoo_scanout_platform.h"
#include "zaparoo_scanout_uapi.h"

#define DEVICE_NAME "zaparoo-scanout"

static DEFINE_MUTEX(owner_lock);
static bool owned;
static struct resource *slot_resources[ZAPAROO_SCANOUT_SLOT_COUNT];
static const unsigned long slot_addresses[] = {
	ZAPAROO_SCANOUT_SLOT0_PHYS, ZAPAROO_SCANOUT_SLOT1_PHYS
};
static const struct zaparoo_scanout_layout layout = {
	.abi_version = ZAPAROO_SCANOUT_ABI_VERSION,
	.slot_count = ZAPAROO_SCANOUT_SLOT_COUNT,
	.max_width = ZAPAROO_SCANOUT_MAX_WIDTH,
	.max_height = ZAPAROO_SCANOUT_MAX_HEIGHT,
	.max_stride_bytes = ZAPAROO_SCANOUT_MAX_STRIDE,
	.slot_capacity_bytes = ZAPAROO_SCANOUT_CAPACITY,
	.map_bytes = ZAPAROO_SCANOUT_MAP_BYTES,
	.flags = ZAPAROO_SCANOUT_WRITE_COMBINE | ZAPAROO_SCANOUT_EXCLUSIVE_OWNER,
	.slots = {
		{ ZAPAROO_SCANOUT_SLOT0_PHYS, 0 },
		{ ZAPAROO_SCANOUT_SLOT1_PHYS, ZAPAROO_SCANOUT_SLOT1_SELECTOR },
	},
};

/* 6.18 no longer exports registered_fb. Check the exact root-level DT window
 * instead: slots are above its complete aperture, independent of live fb mode.
 * Raw property reads deliberately use non-GPL-only exports. Do not mislabel
 * the GPL-3.0 source's loader classification to access GPL-only helpers.
 */
static int validate_platform(void)
{
	struct device_node *node;
	const __be32 *cells;
	int len, ret = -ENODEV;

	if (strcmp(UTS_RELEASE, ZAPAROO_SCANOUT_KERNEL_RELEASE) ||
	    !of_machine_is_compatible(ZAPAROO_SCANOUT_MACHINE))
		return -ENODEV;
	cells = of_get_property(of_root, "#address-cells", &len);
	if (!cells || len != 4 || be32_to_cpup(cells) != 1)
		return -ENODEV;
	cells = of_get_property(of_root, "#size-cells", &len);
	if (!cells || len != 4 || be32_to_cpup(cells) != 1)
		return -ENODEV;
	node = of_find_compatible_node(NULL, NULL, "MiSTer_fb");
	if (!node)
		return -ENODEV;
	cells = of_get_property(node, "reg", &len);
	if (node->parent == of_root && cells && len == 8 &&
	    be32_to_cpup(cells) == ZAPAROO_SCANOUT_FB_DT_BASE &&
	    be32_to_cpup(cells + 1) == ZAPAROO_SCANOUT_FB_DT_BYTES)
		ret = 0;
	of_node_put(node);
	return ret;
}

static void release_slots(void)
{
	unsigned int i;
	for (i = 0; i < ARRAY_SIZE(slot_resources); i++) {
		if (slot_resources[i]) {
			release_mem_region(slot_addresses[i], ZAPAROO_SCANOUT_MAP_BYTES);
			slot_resources[i] = NULL;
		}
	}
}

static int scanout_open(struct inode *inode, struct file *file)
{
	unsigned int i;
	int ret = 0;
	if (!capable(CAP_SYS_RAWIO) || !(file->f_mode & FMODE_READ) ||
	    !(file->f_mode & FMODE_WRITE))
		return -EPERM;
	mutex_lock(&owner_lock);
	if (owned) {
		ret = -EBUSY;
		goto out;
	}
	/* Busy System RAM or another cooperating driver's region also rejects
	 * these requests. Never map Linux-managed RAM on a different boot setup.
	 */
	for (i = 0; i < ARRAY_SIZE(slot_addresses); i++) {
		slot_resources[i] = request_mem_region_exclusive(slot_addresses[i],
			ZAPAROO_SCANOUT_MAP_BYTES, DEVICE_NAME);
		if (!slot_resources[i]) {
			release_slots();
			ret = -EBUSY;
			goto out;
		}
	}
	owned = true;
out:
	mutex_unlock(&owner_lock);
	return ret;
}

static int scanout_release(struct inode *inode, struct file *file)
{
	/* VMA file references postpone this until every mapping is gone, even
	 * after close(fd). The final release may run in a different task.
	 */
	mutex_lock(&owner_lock);
	release_slots();
	owned = false;
	mutex_unlock(&owner_lock);
	return 0;
}

static int scanout_mmap(struct file *file, struct vm_area_struct *vma)
{
	unsigned long phys;
	if (vma->vm_end - vma->vm_start != ZAPAROO_SCANOUT_MAP_BYTES ||
	    !(vma->vm_flags & VM_SHARED) || !(vma->vm_flags & VM_READ) ||
	    !(vma->vm_flags & VM_WRITE) || (vma->vm_flags & VM_EXEC))
		return -EINVAL;
	if (!vma->vm_pgoff)
		phys = ZAPAROO_SCANOUT_SLOT0_PHYS;
	else if (vma->vm_pgoff == ZAPAROO_SCANOUT_SLOT1_SELECTOR / PAGE_SIZE)
		phys = ZAPAROO_SCANOUT_SLOT1_PHYS;
	else
		return -EINVAL;

	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	/* The pinned kernel's __mmap_new_vma invokes this callback before
	 * inserting the new VMA into its tree. Initialize flags here; changing
	 * a published VMA would instead require the per-VMA locking helpers.
	 */
	vm_flags_init(vma, (vma->vm_flags & ~(VM_EXEC | VM_MAYEXEC)) |
		VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP | VM_DONTCOPY);
	if (remap_pfn_range(vma, vma->vm_start, phys >> PAGE_SHIFT,
			ZAPAROO_SCANOUT_MAP_BYTES, vma->vm_page_prot))
		return -EAGAIN;
	return 0;
}

static long scanout_ioctl(struct file *file, unsigned int command, unsigned long argument)
{
	if (command != ZAPAROO_SCANOUT_GET_LAYOUT)
		return -ENOTTY;
	return copy_to_user((void __user *)argument, &layout, sizeof(layout)) ? -EFAULT : 0;
}

static const struct file_operations scanout_fops = {
	.owner = THIS_MODULE,
	.open = scanout_open,
	.release = scanout_release,
	.unlocked_ioctl = scanout_ioctl,
	.mmap = scanout_mmap,
	.llseek = NULL,
};
static struct miscdevice scanout_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DEVICE_NAME,
	.fops = &scanout_fops,
	.mode = 0600,
};

static int __init scanout_init(void)
{
	BUILD_BUG_ON(sizeof(layout) != 64);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_MAP_BYTES & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_SLOT0_PHYS & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_SLOT1_PHYS & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_SLOT1_SELECTOR & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_CAPACITY != ZAPAROO_SCANOUT_MAX_STRIDE * ZAPAROO_SCANOUT_MAX_HEIGHT);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_CAPACITY > ZAPAROO_SCANOUT_MAP_BYTES);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_FB_DT_BASE + ZAPAROO_SCANOUT_FB_DT_BYTES > ZAPAROO_SCANOUT_SLOT0_PHYS);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_SLOT0_PHYS + ZAPAROO_SCANOUT_MAP_BYTES > ZAPAROO_SCANOUT_SLOT1_PHYS);
	if (validate_platform()) {
		pr_err("zaparoo_scanout: unsupported kernel/device-tree platform\n");
		return -ENODEV;
	}
	return misc_register(&scanout_device);
}

static void __exit scanout_exit(void)
{
	misc_deregister(&scanout_device);
}
module_init(scanout_init);
module_exit(scanout_exit);
MODULE_DESCRIPTION("Zaparoo exclusive write-combined scanout slots");
MODULE_AUTHOR("Nigel Breslaw; Zaparoo Project contributors");
/* Linux's loader classification is not the source license. */
MODULE_LICENSE("Proprietary");
MODULE_INFO(source_license, "GPL-3.0-or-later");
MODULE_INFO(kernel_revision, ZAPAROO_SCANOUT_KERNEL_REVISION);
