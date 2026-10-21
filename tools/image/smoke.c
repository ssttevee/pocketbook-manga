#include "vips_bridge.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (pmi_init()) goto fail;
    for (int i = 1; i < argc; ++i) {
        int w, h;
        if (pmi_probe(argv[i], &w, &h)) goto fail;
        void *page = pmi_open(argv[i], 0.5, &w, &h);
        if (!page) goto fail;
        int rw = w < 16 ? w : 16, rh = h < 16 ? h : 16;
        unsigned char pixels[16 * 16];
        if (pmi_region(page, 0, 0, rw, rh, pixels, rw) ||
            pmi_region(page, w - rw, h - rh, rw, rh, pixels, rw)) goto fail;
        pmi_close(page);
        printf("PASS %s %dx%d\n", argv[i], w, h);
    }
    return 0;
fail:
    fprintf(stderr, "%s\n", pmi_error()); return 1;
}
