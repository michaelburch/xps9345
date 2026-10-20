// SPDX-License-Identifier: GPL-2.0
/*
 * Read TZ's row (DRV0) of the AOSS BCM vote table from userspace, awake,
 * with every step fsync'd to LOGFILE before the read it describes. If the
 * read resets the machine, the last line on disk names the address.
 *
 * Read-only, EL2 only (Gunyah does not map the table at EL1). DRV0 has never
 * been read; the ARC vote table read reset this machine, so this may too.
 *
 *   gcc -O2 -Wall -Wextra -o xps-vt-drv0 xps-vt-drv0.c
 *   sudo ./xps-vt-drv0 --canary LOGFILE # DRV2 ACV only (read safely before)
 *   sudo ./xps-vt-drv0 LOGFILE          # canary, then DRV0 MC0
 *   sudo ./xps-vt-drv0 --all LOGFILE    # canary, then DRV0 for every BCM
 */
#ifndef __aarch64__
#error "aarch64 only"
#endif
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define VT_BASE		0x0ba00000UL
#define VT_DRV_STRIDE	0x10000UL
#define BCM_ADDR_BASE	0x50000U
#define APPS_DRV	2
#define MAX_BCM		32

static int log_fd = -1;
static volatile uint64_t current_pa;

struct bcm {
	char name[16];
	uint32_t off;
};

static void emit(const char *buf, size_t len)
{
	ssize_t ignored = write(STDOUT_FILENO, buf, len);

	(void)ignored;
	if (write(log_fd, buf, len) != (ssize_t)len || fsync(log_fd)) {
		perror("log write/fsync");
		exit(4);
	}
}

static void logline(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
	va_end(ap);
	if (n < 0)
		exit(4);
	if (n > (int)sizeof(buf) - 2)
		n = sizeof(buf) - 2;
	buf[n++] = '\n';
	emit(buf, n);
}

static void fault_handler(int sig)
{
	static const char hex[] = "0123456789abcdef";
	char buf[64] = "FAULT signal=";
	size_t n = strlen(buf);
	int i;

	buf[n++] = '0' + sig / 10;
	buf[n++] = '0' + sig % 10;
	memcpy(buf + n, " pa=0x", 6);
	n += 6;
	for (i = 28; i >= 0; i -= 4)
		buf[n++] = hex[(current_pa >> i) & 0xf];
	buf[n++] = '\n';
	if (write(log_fd, buf, n) >= 0)
		fsync(log_fd);
	_exit(3);
}

static uint32_t rd32(const volatile void *p)
{
	uint32_t v;

	asm volatile("ldr %w0, [%1]" : "=r"(v) : "r"(p) : "memory");
	return v;
}

static int read_file(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");

	if (!f || !fgets(buf, len, f)) {
		if (f)
			fclose(f);
		return -1;
	}
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

static int load_bcms(struct bcm *bcms)
{
	FILE *f = fopen("/sys/kernel/debug/cmd-db", "r");
	char line[256], name[16];
	int in_bcm = 0, n = 0;
	unsigned int addr;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		if (!strncmp(line, "Slave ", 6)) {
			in_bcm = !strncmp(line, "Slave BCM", 9);
			continue;
		}
		if (!in_bcm || sscanf(line, "0x%x: %15s [", &addr, name) != 2)
			continue;
		if ((addr & ~0xfffU) != BCM_ADDR_BASE || addr & 3 || n == MAX_BCM) {
			fclose(f);
			return -1;
		}
		snprintf(bcms[n].name, sizeof(bcms[n].name), "%s", name);
		bcms[n++].off = addr - BCM_ADDR_BASE;
	}
	fclose(f);
	return n;
}

static int find_bcm(const struct bcm *bcms, int n, const char *name)
{
	int i;

	for (i = 0; i < n; i++)
		if (!strcmp(bcms[i].name, name))
			return i;
	return -1;
}

static uint32_t read_vt(volatile uint8_t *row, int drv, const struct bcm *b)
{
	uint32_t v;

	current_pa = VT_BASE + drv * VT_DRV_STRIDE + b->off;
	logline("READ drv%d %-4s pa=%#010lx", drv, b->name, (unsigned long)current_pa);
	v = rd32(row + b->off);
	logline("VALUE drv%d %-4s pa=%#010lx vt=%#010x commit=%u valid=%u x=%u y=%u",
		drv, b->name, (unsigned long)current_pa, v, (v >> 30) & 1,
		(v >> 29) & 1, (v >> 14) & 0x3fff, v & 0x3fff);
	return v;
}

int main(int argc, char **argv)
{
	struct bcm bcms[MAX_BCM];
	char boot_id[64] = "?", product[64], bios[64], *dir;
	int all = 0, canary_only = 0, nbcm, mc0, acv, mem_fd, dir_fd, i;
	volatile uint8_t *drv0, *drv2;
	struct sigaction sa = { .sa_handler = fault_handler };
	struct timespec now;
	struct utsname uts;
	const char *path;
	uint32_t v;

	if (argc == 3 && !strcmp(argv[1], "--all"))
		all = 1;
	else if (argc == 3 && !strcmp(argv[1], "--canary"))
		canary_only = 1;
	else if (argc != 2 || argv[1][0] == '-') {
		fprintf(stderr, "usage: %s [--canary|--all] LOGFILE\n", argv[0]);
		return 2;
	}
	path = argv[argc - 1];

	if (geteuid()) {
		fprintf(stderr, "needs root\n");
		return 2;
	}
	if (read_file("/sys/class/dmi/id/product_name", product, sizeof(product)) ||
	    read_file("/sys/class/dmi/id/bios_version", bios, sizeof(bios)) ||
	    strcmp(product, "XPS 13 9345") || strcmp(bios, "2.14.0")) {
		fprintf(stderr, "not an XPS 13 9345 on BIOS 2.14.0\n");
		return 2;
	}
	if (access("/dev/kvm", F_OK)) {
		fprintf(stderr, "no /dev/kvm: not booted at EL2\n");
		return 2;
	}
	nbcm = load_bcms(bcms);
	mc0 = nbcm > 0 ? find_bcm(bcms, nbcm, "MC0") : -1;
	acv = nbcm > 0 ? find_bcm(bcms, nbcm, "ACV") : -1;
	if (mc0 < 0 || acv < 0 || bcms[mc0].off != 0) {
		fprintf(stderr, "cmd-db BCM table unreadable or unexpected\n");
		return 2;
	}

	log_fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0644);
	if (log_fd < 0) {
		perror(path);
		return 2;
	}
	dir = strdup(path);
	dir_fd = dir ? open(dirname(dir), O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
	if (dir_fd < 0 || fsync(dir_fd)) {
		perror("fsync log directory");
		return 2;
	}
	close(dir_fd);
	free(dir);
	if (getenv("SUDO_UID") && getenv("SUDO_GID") &&
	    fchown(log_fd, atoi(getenv("SUDO_UID")), atoi(getenv("SUDO_GID"))))
		perror("fchown log");

	read_file("/proc/sys/kernel/random/boot_id", boot_id, sizeof(boot_id));
	uname(&uts);
	clock_gettime(CLOCK_REALTIME, &now);
	logline("xps-vt-drv0 mode=%s boot_id=%s kernel=%s realtime=%lld",
		canary_only ? "canary" : all ? "all" : "mc0", boot_id,
		uts.release, (long long)now.tv_sec);

	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);
	mem_fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
	if (mem_fd < 0) {
		logline("ABORT open /dev/mem: %s", strerror(errno));
		return 2;
	}
	drv2 = mmap(NULL, 4096, PROT_READ, MAP_SHARED, mem_fd, VT_BASE + APPS_DRV * VT_DRV_STRIDE);
	drv0 = mmap(NULL, 4096, PROT_READ, MAP_SHARED, mem_fd, VT_BASE);
	if (drv2 == MAP_FAILED || drv0 == MAP_FAILED) {
		logline("ABORT mmap /dev/mem: %s", strerror(errno));
		return 2;
	}

	/* Same canary as the in-sleep sampler: APPS ACV holds Linux's mask 0x8. */
	v = read_vt(drv2, APPS_DRV, &bcms[acv]);
	if (!((v >> 29) & 1) || (v & 0x3fff) != 0x8) {
		logline("ABORT canary mismatch, DRV0 not read");
		return 2;
	}
	if (canary_only) {
		logline("DONE canary only, DRV0 not read");
		return 0;
	}

	read_vt(drv0, 0, &bcms[mc0]);
	for (i = 0; all && i < nbcm; i++)
		if (i != mc0)
			read_vt(drv0, 0, &bcms[i]);
	logline("DONE");
	return 0;
}
