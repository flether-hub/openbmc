/* Mock only the kernel boundary. The functions under test are extracted from
 * the patched kernel, not reimplemented here. No hardware is accessed.
 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifndef ETIMEDOUT
#define ETIMEDOUT 110
#endif

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define spin_lock_irqsave(lock, flags) ((void)(lock), (flags) = 0)
#define spin_unlock_irqrestore(lock, flags) ((void)(lock), (void)(flags))
#define netdev_warn(...) ((void)0)
#define netdev_info(...) ((void)0)
#define netdev_err(...) ((void)0)
#define netdev_dbg(...) ((void)0)
#define netdev_alert(...) ((void)0)
#define IS_ENABLED(x) 0
#define unlikely(x) (x)
#define rtnl_lock() ((void)0)
#define rtnl_unlock() ((void)0)
#define fallthrough ((void)0)
#define NCSI_REQ_FLAG_EVENT_DRIVEN 1
#define NCSI_REQ_FLAG_NETLINK_DRIVEN 2
#define NCSI_REQ_FLAG_CONFIG 4
#define NCSI_REQ_START_IDX 1
#define NCSI_RESERVED_CHANNEL 31
#define NCSI_CHANNEL_INACTIVE 1
#define NCSI_CHANNEL_ACTIVE 2
#define NCSI_CHANNEL_INVISIBLE 3
#define NCSI_CHANNEL_FAILED 4
#define NCSI_DEV_HWA 2
#define NCSI_DEV_RESHUFFLE 4
#define NCSI_DEV_RESET 8
#define NCSI_MODE_LINK 0
#define NCSI_CAP_BC 0
#define NCSI_CAP_GENERIC 1
#define NCSI_CAP_AEN 2
#define NCSI_CAP_GENERIC_MC 0x10
#define NCSI_CAP_AEN_MASK 0xff
#define NCSI_CAP_VLAN_NO 1
#define ncsi_dev_state_functional 0x100
#define ncsi_dev_state_registered 0
#define ncsi_dev_state_probe 0x200
#define ncsi_dev_state_config 0x300
#define ncsi_dev_state_suspend 0x400

enum {
    NCSI_PKT_CMD_CIS, NCSI_PKT_CMD_SP, NCSI_PKT_CMD_DP, NCSI_PKT_CMD_EC,
    NCSI_PKT_CMD_DC, NCSI_PKT_CMD_ECNT = 6, NCSI_PKT_CMD_DCNT,
    NCSI_PKT_CMD_AE, NCSI_PKT_CMD_GLS = 10, NCSI_PKT_CMD_SVF,
    NCSI_PKT_CMD_EV, NCSI_PKT_CMD_DV, NCSI_PKT_CMD_SMA,
    NCSI_PKT_CMD_EBF = 16, NCSI_PKT_CMD_DGMF = 21,
    NCSI_PKT_CMD_OEM = 0x50, NCSI_PKT_CMD_GMCMA = 0x58
};
struct ncsi_dev_priv;
struct list_head { bool empty; };
struct net_device { unsigned char dev_addr[6]; bool dormant, carrier; };
struct ncsi_dev { struct net_device *dev; int state; bool link_up; };
struct ncsi_cmd_arg {
    struct ncsi_dev_priv *ndp;
    unsigned char type, id, package, channel;
    unsigned short payload;
    unsigned int req_flags;
    union { unsigned char bytes[16]; unsigned short words[8]; unsigned int dwords[4]; };
    unsigned char *data;
    void *info;
};
struct ncsi_channel;
struct ncsi_package {
    unsigned char id;
    struct ncsi_channel *preferred_channel, *channel;
};
struct ncsi_channel {
    unsigned char id;
    int state, lock;
    bool config_failed, reconfigure_needed;
    struct ncsi_package *package;
    struct { unsigned int cap; } caps[3];
    struct { unsigned int data[4]; } modes[1];
    struct { unsigned int major, minor, mf_id; } version;
    struct list_head link;
};
struct sk_buff { int unused; };
struct ncsi_request {
    unsigned char id;
    bool used, enabled;
    unsigned int flags;
    int status, timer;
    struct ncsi_dev_priv *ndp;
    struct sk_buff *cmd, *rsp;
};
struct ncsi_dev_priv {
    struct ncsi_dev ndev;
    int lock, work, pending_mac;
    unsigned int flags, pending_req_num, request_id, channel_probe_id, channel_count;
    struct ncsi_request requests[256];
    struct ncsi_cmd_arg config_cmd;
    unsigned int config_retries;
    int config_error;
    bool config_pending, config_cleanup;
    struct ncsi_package *active_package;
    struct ncsi_package *test_package;
    struct ncsi_channel *active_channel, *hot_channel;
    struct list_head vlan_vids, channel_queue;
};
#define NCSI_FOR_EACH_CHANNEL(np, nc) for ((nc) = (np)->channel; (nc); (nc) = NULL)
#define NCSI_FOR_EACH_PACKAGE(ndp, np) for ((np) = (ndp)->test_package; (np); (np) = NULL)
#define list_for_each_entry_safe(nc, tmp, head, member) for ((nc) = (tmp) = NULL; (nc); (nc) = (tmp))
#define list_del_rcu(link) ((void)(link))
#define list_del_init(link) ((link)->empty = true)
#define TO_NCSI_DEV_PRIV(nd) ((struct ncsi_dev_priv *)(nd))

static unsigned int sent[256], schedules, monitors, frees, timers, reports;
static unsigned int request_ids[256], id_count;
static int fail_command = -1, remaining_failures, failure_status;
static int fail_cleanup = -1;
static int remaining_cleanup, cleanup_status;
static unsigned char expected_mac[6] = {2, 3, 4, 5, 6, 7};
static struct ncsi_request *ncsi_alloc_request(struct ncsi_dev_priv *, unsigned int);
static void ncsi_free_request(struct ncsi_request *);
static int ncsi_config_xmit_cmd(struct ncsi_cmd_arg *);
static bool ncsi_retry_config(struct ncsi_dev_priv *);
static int ncsi_reset_dev(struct ncsi_dev *);
static void ftgmac100_ncsi_handler(struct ncsi_dev *);
static void netif_dormant_on(struct net_device *dev) { dev->dormant = true; }
static void netif_dormant_off(struct net_device *dev) { dev->dormant = false; }
static void schedule_work(int *work) { (void)work; schedules++; }
static void timer_delete_sync(int *timer) { (void)timer; timers++; }
static void consume_skb(struct sk_buff *skb) { if (skb) { frees++; free(skb); } }
static bool list_empty(struct list_head *head) { return head->empty; }
static void list_add_tail_rcu(struct list_head *a, struct list_head *b) { a->empty = b->empty = false; }
static int dev_set_mac_address(struct net_device *dev, int *mac, void *unused) {
    (void)dev; (void)mac; (void)unused; return 0;
}
static void ncsi_report_link(struct ncsi_dev_priv *ndp, bool down) {
    assert(down); reports++; ndp->ndev.state = ncsi_dev_state_functional;
    ndp->ndev.link_up = false; ftgmac100_ncsi_handler(&ndp->ndev);
}
static void ncsi_start_channel_monitor(struct ncsi_channel *nc) { (void)nc; monitors++; }
static void ncsi_stop_channel_monitor(struct ncsi_channel *nc) { (void)nc; }
static void ncsi_process_next_channel(struct ncsi_dev_priv *ndp) {
    ndp->ndev.state = ncsi_dev_state_functional;
    ndp->ndev.link_up = ndp->active_channel->state == NCSI_CHANNEL_ACTIVE;
    ftgmac100_ncsi_handler(&ndp->ndev);
}
static int ncsi_choose_active_channel(struct ncsi_dev_priv *ndp) {
    assert(!ndp->active_channel->config_failed);
    ndp->active_channel->state = NCSI_CHANNEL_INVISIBLE;
    ndp->ndev.state = ncsi_dev_state_config;
    return 0;
}
static bool ncsi_channel_is_tx(struct ncsi_dev_priv *ndp, struct ncsi_channel *nc) {
    (void)ndp; (void)nc; return true;
}
static int clear_one_vid(struct ncsi_dev_priv *ndp, struct ncsi_channel *nc, struct ncsi_cmd_arg *nca) {
    (void)ndp; (void)nc; (void)nca; return -1;
}
static int set_one_vid(struct ncsi_dev_priv *ndp, struct ncsi_channel *nc, struct ncsi_cmd_arg *nca) {
    (void)ndp; (void)nc; (void)nca; return -1;
}
static int ncsi_gma_handler(struct ncsi_cmd_arg *nca, unsigned int id) {
    (void)nca; (void)id; return -1;
}

/* Allocate/free the real request object and inject transport outcomes. */
static int ncsi_xmit_cmd(struct ncsi_cmd_arg *nca) {
    struct ncsi_dev_priv *ndp = nca->ndp;
    struct ncsi_request *nr;
    int status = 0;
    sent[nca->type]++;
    if (nca->type == NCSI_PKT_CMD_SMA) {
        assert(memcmp(nca->bytes, expected_mac, 6) == 0);
        assert(nca->bytes[6] == 1 && nca->bytes[7] == 1);
    }
    if (!ndp->config_cleanup && nca->type == fail_command && remaining_failures > 0) {
        remaining_failures--; status = failure_status;
    }
    if (ndp->config_cleanup && nca->type == fail_cleanup && remaining_cleanup > 0) {
        remaining_cleanup--; status = cleanup_status;
    }
    if (status == -ENOMEM) return status; /* No request allocated. */
    nr = ncsi_alloc_request(ndp, nca->req_flags);
    assert(nr);
    request_ids[id_count++] = nr->id;
    nr->cmd = calloc(1, sizeof(*nr->cmd));
    nr->enabled = status != -ETIMEDOUT; /* Timeout callback already disarmed its timer. */
    if (status != -ETIMEDOUT) {
        nr->rsp = calloc(1, sizeof(*nr->rsp));
        nr->status = status;
    }
    if (nca->type == NCSI_PKT_CMD_GLS && !status)
        ndp->active_channel->modes[NCSI_MODE_LINK].data[2] = 1;
    ncsi_free_request(nr);
    return status == -EIO ? status : 0; /* Synchronous send failure vs response failure. */
}

#include "ncsi-functions.inc"

static void initialize(struct ncsi_dev_priv *ndp, struct ncsi_package *np,
                       struct ncsi_channel *nc, struct net_device *dev) {
    unsigned int i;
    memset(ndp, 0, sizeof(*ndp)); memset(np, 0, sizeof(*np)); memset(nc, 0, sizeof(*nc));
    memset(sent, 0, sizeof(sent)); schedules = monitors = frees = timers = reports = id_count = 0;
    fail_command = fail_cleanup = -1; remaining_failures = 0;
    remaining_cleanup = 99; cleanup_status = -ETIMEDOUT;
    ndp->ndev.dev = dev; ndp->ndev.state = ncsi_dev_state_config;
    ndp->active_package = ndp->test_package = np; ndp->active_channel = nc;
    ndp->channel_count = 1; ndp->channel_queue.empty = true;
    ndp->request_id = 1; ndp->vlan_vids.empty = true;
    for (i = 0; i < ARRAY_SIZE(ndp->requests); i++) {
        ndp->requests[i].id = i; ndp->requests[i].ndp = ndp;
    }
    np->id = 1; np->channel = nc; nc->id = 2; nc->package = np;
    nc->state = NCSI_CHANNEL_INVISIBLE; nc->caps[NCSI_CAP_BC].cap = 7;
    memcpy(dev->dev_addr, expected_mac, 6);
    dev->dormant = dev->carrier = true;
}

static void run(struct ncsi_dev_priv *ndp) {
    unsigned int steps = 0, i;
    while (ndp->ndev.state != ncsi_dev_state_functional) {
        assert(++steps < 100);
        switch (ndp->ndev.state & ncsi_dev_state_major) {
        case ncsi_dev_state_config: ncsi_configure_channel(ndp); break;
        case ncsi_dev_state_suspend: ncsi_suspend_channel(ndp); break;
        default: assert(false);
        }
    }
    assert(ndp->pending_req_num == 0);
    for (i = 0; i < ARRAY_SIZE(ndp->requests); i++) assert(!ndp->requests[i].used);
    for (i = 1; i < id_count; i++) assert(request_ids[i] != request_ids[i-1]);
    assert(frees >= timers);
    assert(ndp->ndev.dev->carrier);
    assert(ndp->ndev.dev->dormant == (ndp->active_channel->state != NCSI_CHANNEL_ACTIVE));
}

int main(void) {
    struct ncsi_dev_priv ndp;
    struct ncsi_package np;
    struct ncsi_channel nc;
    struct net_device dev;
    const int required[] = {NCSI_PKT_CMD_SP, NCSI_PKT_CMD_CIS, NCSI_PKT_CMD_SMA,
        NCSI_PKT_CMD_EBF, NCSI_PKT_CMD_ECNT, NCSI_PKT_CMD_EC, NCSI_PKT_CMD_GLS};
    const int errors[] = {-ETIMEDOUT, -EPERM, -EINVAL, -EIO, -ENOMEM};
    const int cleanup[] = {NCSI_PKT_CMD_SP, NCSI_PKT_CMD_DCNT, NCSI_PKT_CMD_DC, NCSI_PKT_CMD_DP};
    unsigned int i, j, cases = 0;
    initialize(&ndp, &np, &nc, &dev); run(&ndp);
    assert(nc.state == NCSI_CHANNEL_ACTIVE && monitors == 1 && !reports); cases++;
    initialize(&ndp, &np, &nc, &dev);
    ndp.ndev.link_up = true;
    ftgmac100_ncsi_handler(&ndp.ndev);
    assert(dev.dormant && dev.carrier); cases++;
    ndp.ndev.state = ncsi_dev_state_functional;
    ftgmac100_ncsi_handler(&ndp.ndev);
    assert(!dev.dormant && dev.carrier); cases++;
    ndp.ndev.link_up = false;
    ftgmac100_ncsi_handler(&ndp.ndev);
    assert(dev.dormant && dev.carrier); cases++;
    ndp.ndev.link_up = true;
    ftgmac100_ncsi_handler(&ndp.ndev);
    assert(!dev.dormant && dev.carrier); cases++;
    for (i = 0; i < ARRAY_SIZE(required); i++) {
        for (j = 0; j < ARRAY_SIZE(errors); j++) {
            initialize(&ndp, &np, &nc, &dev);
            fail_command = required[i]; remaining_failures = 2; failure_status = errors[j];
            run(&ndp);
            assert(nc.state == NCSI_CHANNEL_ACTIVE && monitors == 1);
            assert(sent[required[i]] == 3 && !nc.config_failed && !reports); cases++;
        }
        initialize(&ndp, &np, &nc, &dev);
        fail_command = required[i]; remaining_failures = 3; failure_status = -ETIMEDOUT;
        run(&ndp);
        assert(sent[required[i]] == 4 && nc.state == NCSI_CHANNEL_ACTIVE); cases++;
    }
    for (i = 0; i < ARRAY_SIZE(required); i++) {
        initialize(&ndp, &np, &nc, &dev);
        fail_command = required[i]; remaining_failures = 99; failure_status = -ETIMEDOUT;
        run(&ndp);
        assert(sent[required[i]] == 4 + (required[i] == NCSI_PKT_CMD_SP) && nc.config_failed);
        assert(nc.state == NCSI_CHANNEL_INACTIVE && monitors == 0);
        assert(sent[NCSI_PKT_CMD_DCNT] && sent[NCSI_PKT_CMD_DC] && sent[NCSI_PKT_CMD_DP]); cases++;
    }
    initialize(&ndp, &np, &nc, &dev);
    fail_command = NCSI_PKT_CMD_SMA; remaining_failures = 99; failure_status = -EPERM;
    fail_cleanup = NCSI_PKT_CMD_DCNT; run(&ndp);
    assert(sent[NCSI_PKT_CMD_DCNT] == 4 && nc.state == NCSI_CHANNEL_FAILED);
    assert(reports == 1 && monitors == 0); cases++;
    /* A new interface start clears the per-start blacklist. The real reset
     * must clean FAILED before allowing this channel to be configured again. */
    nc.config_failed = false; ndp.config_pending = ndp.config_cleanup = false;
    fail_command = fail_cleanup = -1;
    assert(ncsi_reset_dev(&ndp.ndev) == 0 && ndp.config_cleanup);
    run(&ndp);
    assert(nc.state == NCSI_CHANNEL_ACTIVE && monitors == 1); cases++;
    for (i = 0; i < ARRAY_SIZE(cleanup); i++) {
        for (j = 0; j < ARRAY_SIZE(errors); j++) {
            initialize(&ndp, &np, &nc, &dev);
            fail_command = NCSI_PKT_CMD_SMA; remaining_failures = 99; failure_status = -EPERM;
            fail_cleanup = cleanup[i]; remaining_cleanup = 2; cleanup_status = errors[j];
            run(&ndp);
            assert(nc.state == NCSI_CHANNEL_INACTIVE && nc.config_failed && monitors == 0);
            assert(sent[cleanup[i]] == 3 + (cleanup[i] == NCSI_PKT_CMD_SP)); cases++;
        }
    }
    initialize(&ndp, &np, &nc, &dev);
    fail_command = NCSI_PKT_CMD_DV; remaining_failures = 99; failure_status = -EPERM;
    run(&ndp);
    assert(sent[NCSI_PKT_CMD_DV] == 1 && nc.state == NCSI_CHANNEL_ACTIVE); cases++;
    initialize(&ndp, &np, &nc, &dev);
    nc.caps[NCSI_CAP_BC].cap = 0;
    fail_command = NCSI_PKT_CMD_EBF; remaining_failures = 99; failure_status = -EPERM;
    run(&ndp);
    assert(sent[NCSI_PKT_CMD_EBF] == 1 && nc.state == NCSI_CHANNEL_ACTIVE); cases++;
    printf("PASS: %u NC-SI config/timeout/rejection/send-error/cleanup cases\n", cases);
    return 0;
}
