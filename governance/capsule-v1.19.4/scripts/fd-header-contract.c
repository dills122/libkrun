#include <stdint.h>
#include <libkrun.h>

typedef int32_t (*raw_root_fd_fn)(uint32_t, int, uint64_t, uint64_t, uint64_t);

static raw_root_fd_fn raw_root_fd_api = krun_add_read_only_raw_root_fd;

int main(void)
{
    return raw_root_fd_api == 0;
}
