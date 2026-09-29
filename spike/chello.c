/* Minimal C fuse_main() mount, to check libfuse-side log output */
#define FUSE_USE_VERSION 31
#include <fuse.h>
#include <string.h>
#include <errno.h>
static int ga(const char *p, struct stat *st, struct fuse_file_info *fi)
{ memset(st, 0, sizeof(*st)); if (strcmp(p, "/")) return -ENOENT; st->st_mode = S_IFDIR | 0555; st->st_nlink = 2; return 0; }
static const struct fuse_operations ops = { .getattr = ga };
int main(int argc, char *argv[]) { return fuse_main(argc, argv, &ops, NULL); }
