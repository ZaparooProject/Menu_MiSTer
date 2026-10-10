// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Nigel Breslaw
// Zaparoo fork: namespaced device, 6.18 platform validation, lifetime ownership.

/* Bounded write-combined scanout slots: two RGB565 HDMI slots and Menu's native
 * video window, plus a wait on the native raster's vertical sync. No FPGA
 * commands or DMA. Reservations and the sync interrupt belong to the open file
 * and all its VMAs, not module residency.
 */
#include <linux/build_bug.h>
#include <linux/capability.h>
#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/ioport.h>
#include <linux/irq.h>
#include <linux/irqdomain.h>
#include <linux/jiffies.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_irq.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/utsname.h>
#include <linux/wait.h>
#include "zaparoo_scanout_platform.h"
#include "zaparoo_scanout_uapi.h"

#define DEVICE_NAME "zaparoo-scanout"

static DEFINE_MUTEX(owner_lock);
static bool owned;
static struct resource *slot_resources[ZAPAROO_SCANOUT_SLOT_COUNT];
static struct resource *native_resource;
static int native_irq;
static u32 native_sync_count;
static DECLARE_WAIT_QUEUE_HEAD(native_sync_wait);
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
	.flags = ZAPAROO_SCANOUT_WRITE_COMBINE | ZAPAROO_SCANOUT_EXCLUSIVE_OWNER |
		ZAPAROO_SCANOUT_NATIVE_WINDOW | ZAPAROO_SCANOUT_NATIVE_VBLANK,
	.slots = {
		{ ZAPAROO_SCANOUT_SLOT0_PHYS, 0 },
		{ ZAPAROO_SCANOUT_SLOT1_PHYS, ZAPAROO_SCANOUT_SLOT1_SELECTOR },
	},
	.native_control_offset_bytes = ZAPAROO_SCANOUT_NATIVE_CONTROL_SELECTOR,
	.native_control_bytes = ZAPAROO_SCANOUT_NATIVE_CONTROL_BYTES,
	.native_pixels_offset_bytes = ZAPAROO_SCANOUT_NATIVE_PIXELS_SELECTOR,
	.native_pixels_bytes = ZAPAROO_SCANOUT_NATIVE_PIXELS_BYTES,
};

/* 6.18 no longer exports registered_fb. Check the exact root-level DT window
 * instead: slots are above its complete aperture, independent of live fb mode.
 */
static int validate_platform(void)
{
	struct device_node *node;
	const __be32 *cells;
	int len, ret = -ENODEV;

	if (strcmp(utsname()->release, ZAPAROO_SCANOUT_KERNEL_RELEASE) ||
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

static irqreturn_t native_sync_irq(int irq, void *data)
{
	WRITE_ONCE(native_sync_count, native_sync_count + 1);
	wake_up_interruptible(&native_sync_wait);
	return IRQ_HANDLED;
}

/* The stock device tree describes only MiSTer_fb's HDMI interrupt, so map
 * the neighbouring FPGA line on that node's interrupt controller directly.
 * Caller holds owner_lock.
 */
static int native_sync_start(void)
{
	struct irq_fwspec spec = {
		.param_count = 3,
		.param = { 0, ZAPAROO_SCANOUT_NATIVE_SYNC_SPI, IRQ_TYPE_EDGE_RISING },
	};
	struct device_node *node, *controller;
	int irq, ret;

	if (native_irq)
		return 0;
	node = of_find_compatible_node(NULL, NULL, "MiSTer_fb");
	if (!node)
		return -ENODEV;
	controller = of_irq_find_parent(node);
	of_node_put(node);
	if (!controller)
		return -ENODEV;
	spec.fwnode = of_fwnode_handle(controller);
	irq = irq_create_fwspec_mapping(&spec);
	of_node_put(controller);
	if (!irq)
		return -ENXIO;
	ret = request_irq(irq, native_sync_irq, 0, DEVICE_NAME, &native_sync_wait);
	if (ret) {
		irq_dispose_mapping(irq);
		return ret;
	}
	native_irq = irq;
	return 0;
}

static void native_sync_stop(void)
{
	if (!native_irq)
		return;
	free_irq(native_irq, &native_sync_wait);
	irq_dispose_mapping(native_irq);
	native_irq = 0;
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
	if (native_resource) {
		release_mem_region(ZAPAROO_SCANOUT_NATIVE_PHYS, ZAPAROO_SCANOUT_NATIVE_BYTES);
		native_resource = NULL;
	}
}

/* HDMI-only clients never touch the native window, so it is reserved by its
 * first mapping instead of at open.
 */
static int reserve_native(void)
{
	int ret = 0;

	mutex_lock(&owner_lock);
	if (!native_resource) {
		native_resource = request_mem_region_exclusive(ZAPAROO_SCANOUT_NATIVE_PHYS,
			ZAPAROO_SCANOUT_NATIVE_BYTES, DEVICE_NAME);
		if (!native_resource)
			ret = -EBUSY;
	}
	mutex_unlock(&owner_lock);
	return ret;
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
	native_sync_stop();
	release_slots();
	owned = false;
	mutex_unlock(&owner_lock);
	return 0;
}

static int scanout_mmap(struct file *file, struct vm_area_struct *vma)
{
	unsigned long phys, bytes = ZAPAROO_SCANOUT_MAP_BYTES;
	bool native = true, write_combine = true;
	int ret;

	if (!(vma->vm_flags & VM_SHARED) || !(vma->vm_flags & VM_READ) ||
	    !(vma->vm_flags & VM_WRITE) || (vma->vm_flags & VM_EXEC))
		return -EINVAL;
	if (!vma->vm_pgoff) {
		phys = ZAPAROO_SCANOUT_SLOT0_PHYS;
		native = false;
	} else if (vma->vm_pgoff == ZAPAROO_SCANOUT_SLOT1_SELECTOR / PAGE_SIZE) {
		phys = ZAPAROO_SCANOUT_SLOT1_PHYS;
		native = false;
	} else if (vma->vm_pgoff == ZAPAROO_SCANOUT_NATIVE_CONTROL_SELECTOR / PAGE_SIZE) {
		/* The reader latches these words; they must never sit in a
		 * write-combining buffer behind the pixels they publish.
		 */
		phys = ZAPAROO_SCANOUT_NATIVE_PHYS;
		bytes = ZAPAROO_SCANOUT_NATIVE_CONTROL_BYTES;
		write_combine = false;
	} else if (vma->vm_pgoff == ZAPAROO_SCANOUT_NATIVE_PIXELS_SELECTOR / PAGE_SIZE) {
		phys = ZAPAROO_SCANOUT_NATIVE_PHYS + ZAPAROO_SCANOUT_NATIVE_CONTROL_BYTES;
		bytes = ZAPAROO_SCANOUT_NATIVE_PIXELS_BYTES;
	} else {
		return -EINVAL;
	}
	if (vma->vm_end - vma->vm_start != bytes)
		return -EINVAL;
	if (native) {
		ret = reserve_native();
		if (ret)
			return ret;
	}

	vma->vm_page_prot = write_combine ? pgprot_writecombine(vma->vm_page_prot) :
		pgprot_noncached(vma->vm_page_prot);
	/* The pinned kernel's __mmap_new_vma invokes this callback before
	 * inserting the new VMA into its tree. Initialize flags here; changing
	 * a published VMA would instead require the per-VMA locking helpers.
	 */
	vm_flags_init(vma, (vma->vm_flags & ~(VM_EXEC | VM_MAYEXEC)) |
		VM_IO | VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP | VM_DONTCOPY);
	if (remap_pfn_range(vma, vma->vm_start, phys >> PAGE_SHIFT, bytes,
			vma->vm_page_prot))
		return -EAGAIN;
	return 0;
}

static long wait_native_vblank(unsigned long argument)
{
	u32 seen, count;
	long left;
	int ret;

	mutex_lock(&owner_lock);
	ret = native_sync_start();
	mutex_unlock(&owner_lock);
	if (ret)
		return ret;
	seen = READ_ONCE(native_sync_count);
	left = wait_event_interruptible_timeout(native_sync_wait,
		READ_ONCE(native_sync_count) != seen,
		msecs_to_jiffies(ZAPAROO_SCANOUT_NATIVE_SYNC_TIMEOUT_MSEC));
	if (left < 0)
		return left;
	if (!left)
		return -ETIMEDOUT;
	count = READ_ONCE(native_sync_count);
	return put_user(count, (u32 __user *)argument) ? -EFAULT : 0;
}

static long scanout_ioctl(struct file *file, unsigned int command, unsigned long argument)
{
	switch (command) {
	case ZAPAROO_SCANOUT_GET_LAYOUT:
		return copy_to_user((void __user *)argument, &layout, sizeof(layout)) ? -EFAULT : 0;
	case ZAPAROO_SCANOUT_WAIT_NATIVE_VBLANK:
		return wait_native_vblank(argument);
	default:
		return -ENOTTY;
	}
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
	BUILD_BUG_ON(ZAPAROO_SCANOUT_SLOT1_PHYS + ZAPAROO_SCANOUT_MAP_BYTES > ZAPAROO_SCANOUT_NATIVE_PHYS);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_PHYS & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_CONTROL_BYTES & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_PIXELS_BYTES & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_CONTROL_SELECTOR & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_PIXELS_SELECTOR & ~PAGE_MASK);
	BUILD_BUG_ON(ZAPAROO_SCANOUT_NATIVE_CONTROL_BYTES + ZAPAROO_SCANOUT_NATIVE_PIXELS_BYTES !=
		ZAPAROO_SCANOUT_NATIVE_BYTES);
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
MODULE_LICENSE("GPL");
MODULE_INFO(source_license, "GPL-3.0-or-later");
MODULE_INFO(kernel_revision, ZAPAROO_SCANOUT_KERNEL_REVISION);
