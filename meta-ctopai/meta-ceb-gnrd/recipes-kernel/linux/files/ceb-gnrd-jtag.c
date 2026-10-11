// SPDX-License-Identifier: GPL-2.0-only
/* CEB-GNRD AST2600 Master-1, dedicated pins, bounded software clock batches.
 * Register layout follows ASPEED's Linux JTAG driver (AMD OpenBMC).
 * No JTAG signals are driven at probe. This device is root-only, single-open.
 */
#include <linux/capability.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/reset.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#define CTRL 0x08
#define SW 0x10
#define IDLE 0x18
#define GLOBAL 0x30
#define OUTPUT (BIT(31) | BIT(30))
#define SW_EN BIT(19)
#define SW_CLK BIT(18)
#define SW_TMS BIT(17)
#define SW_TDIO BIT(16)
#define MAX_CLOCKS 4096
/* Fixed-width, pointer-free ABI. One byte per clock: TMS bit0, TDI bit1;
 * returned byte adds sampled TDO in bit2. The period is a MINIMUM.
 */
struct ceb_jtag_batch {
 __u32 count;
 __u32 half_period_ns;
 __u8 bits[MAX_CLOCKS];
};
#define CEB_JTAG_CLOCK _IOWR('J', 0x40, struct ceb_jtag_batch)
struct ceb_jtag {
 void __iomem *base;
 struct clk *clk;
 struct reset_control *rst;
 struct miscdevice misc;
 struct mutex lock;
 bool opened;
};

static int ceb_open(struct inode *inode, struct file *file)
{
 struct ceb_jtag *j = container_of(file->private_data, struct ceb_jtag, misc);
 int rc;

 if (!capable(CAP_SYS_RAWIO))
  return -EPERM;
 mutex_lock(&j->lock);
 if (j->opened) {
  rc = -EBUSY;
  goto out;
 }
 rc = clk_prepare_enable(j->clk);
 if (rc)
  goto out;
 rc = reset_control_deassert(j->rst);
 if (rc) {
  clk_disable_unprepare(j->clk);
  goto out;
 }
 /* Leave nTRST high; TAP reset is performed with TMS clocks by the player.
  * Do not select the GPIOI Master-2 pin group on this board.
  */
 writel(0, j->base + GLOBAL);
 writel(0, j->base + CTRL);
 writel(BIT(31), j->base + IDLE);
 writel(SW_EN, j->base + SW);
 writel(OUTPUT, j->base + CTRL);
 j->opened = true;
 file->private_data = j;
 rc = nonseekable_open(inode, file);
out:
 mutex_unlock(&j->lock);
 return rc;
}

static long ceb_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
 struct ceb_jtag *j = file->private_data;
 struct ceb_jtag_batch *b;
 u32 i, val;
 long rc = 0;

 if (cmd != CEB_JTAG_CLOCK)
  return -ENOTTY;
 b = memdup_user((void __user *)arg, sizeof(*b));
 if (IS_ERR(b))
  return PTR_ERR(b);
 if (!b->count || b->count > MAX_CLOCKS ||
     b->half_period_ns < 500 || b->half_period_ns > 5000) {
  rc = -EINVAL;
  goto out;
 }
 for (i = 0; i < b->count; i++)
  if (b->bits[i] & ~3) {
   rc = -EINVAL;
   goto out;
  }
 mutex_lock(&j->lock);
 for (i = 0; i < b->count; i++) {
  val = SW_EN | ((b->bits[i] & 1) ? SW_TMS : 0) |
        ((b->bits[i] & 2) ? SW_TDIO : 0);
  writel(val, j->base + SW);
  readl(j->base + SW); /* Flush before setup time. */
  ndelay(b->half_period_ns);
  writel(val | SW_CLK, j->base + SW);
  readl(j->base + SW);
  ndelay(b->half_period_ns);
  if (readl(j->base + SW) & SW_TDIO)
   b->bits[i] |= 4;
  writel(val, j->base + SW);
  if (!(i & 255))
   cond_resched();
 }
 mutex_unlock(&j->lock);
 if (copy_to_user((void __user *)arg, b, sizeof(*b)))
  rc = -EFAULT;
out:
 kfree(b);
 return rc;
}

static int ceb_release(struct inode *inode, struct file *file)
{
 struct ceb_jtag *j = file->private_data;

 mutex_lock(&j->lock);
 /* Disable output without issuing a CPLD reset or any configuration opcode. */
 writel(0, j->base + CTRL);
 writel(0, j->base + GLOBAL);
 writel(0, j->base + SW);
 clk_disable_unprepare(j->clk);
 j->opened = false;
 mutex_unlock(&j->lock);
 return 0;
}

static const struct file_operations ceb_fops = {
 .owner = THIS_MODULE,
 .open = ceb_open,
 .release = ceb_release,
 .unlocked_ioctl = ceb_ioctl,
 .compat_ioctl = ceb_ioctl,
};

static void ceb_deregister(void *data)
{
 misc_deregister(data);
}

static int ceb_probe(struct platform_device *pdev)
{
 struct ceb_jtag *j;

 j = devm_kzalloc(&pdev->dev, sizeof(*j), GFP_KERNEL);
 if (!j)
  return -ENOMEM;
 j->base = devm_platform_ioremap_resource(pdev, 0);
 if (IS_ERR(j->base))
  return PTR_ERR(j->base);
 j->clk = devm_clk_get(&pdev->dev, NULL);
 if (IS_ERR(j->clk))
  return dev_err_probe(&pdev->dev, PTR_ERR(j->clk), "JTAG clock\n");
 j->rst = devm_reset_control_get_exclusive(&pdev->dev, NULL);
 if (IS_ERR(j->rst))
  return dev_err_probe(&pdev->dev, PTR_ERR(j->rst), "JTAG reset\n");
 mutex_init(&j->lock);
 j->misc.minor = MISC_DYNAMIC_MINOR;
 j->misc.name = "ceb-cpld-jtag";
 j->misc.fops = &ceb_fops;
 j->misc.parent = &pdev->dev;
 j->misc.mode = 0600;
 {
  int rc = misc_register(&j->misc);
  if (rc)
   return rc;
  return devm_add_action_or_reset(&pdev->dev, ceb_deregister, &j->misc);
 }
}

static const struct of_device_id ceb_match[] = {
 { .compatible = "ctopai,ceb-gnrd-jtag-master1" },
 {}
};
MODULE_DEVICE_TABLE(of, ceb_match);
static struct platform_driver ceb_driver = {
 .probe = ceb_probe,
 .driver = { .name = "ceb-gnrd-jtag", .of_match_table = ceb_match,
             .suppress_bind_attrs = true },
};
module_platform_driver(ceb_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("CEB-GNRD AST2600 dedicated JTAG Master-1");
