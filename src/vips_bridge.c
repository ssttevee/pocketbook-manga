#include "vips_bridge.h"
#include <vips/vips.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <math.h>

typedef struct { VipsImage *image; } Page;

int pmi_init(void) {
    g_setenv("VIPS_DISC_THRESHOLD", "8m", FALSE);
    if (VIPS_INIT("pocketmanga")) return -1;
    vips_concurrency_set(1);
    vips_cache_set_max(0);
    vips_cache_set_max_mem(8 * 1024 * 1024);
    vips_cache_set_max_files(8);
    return 0;
}

/* Do not expose libvips' broad file-loader registry to downloaded content. */
static VipsImage *load(const char *path, int shrink) {
    const char *loader = vips_foreign_find_load(path);
    static const char *const allowed[] = {
        "VipsForeignLoadJpegFile", "VipsForeignLoadPngFile",
        "VipsForeignLoadWebpFile", "VipsForeignLoadNsgifFile",
        "VipsForeignLoadHeifFile", "VipsForeignLoadJxlFile",
        "VipsForeignLoadJp2kFile"
    };
    if (!loader) return NULL;
    for (size_t i = 0; i < sizeof allowed / sizeof *allowed; ++i)
        if (strcmp(loader, allowed[i]) == 0) {
            if (shrink > 1 && (strcmp(loader, "VipsForeignLoadJpegFile") == 0 ||
                              strcmp(loader, "VipsForeignLoadWebpFile") == 0))
                return vips_image_new_from_file(path, "access", VIPS_ACCESS_RANDOM,
                    "fail_on", VIPS_FAIL_ON_ERROR, "shrink", shrink, NULL);
            return vips_image_new_from_file(path, "access", VIPS_ACCESS_RANDOM,
                "fail_on", VIPS_FAIL_ON_ERROR, NULL);
        }
    vips_error("pocketmanga", "unsupported image format (%s)", loader);
    return NULL;
}

static VipsImage *oriented(const char *path, int shrink) {
    VipsImage *source = load(path, shrink), *image = NULL;
    if (!source) return NULL;
    if (source->Xsize <= 0 || source->Ysize <= 0 ||
        source->Xsize > 1000000 || source->Ysize > 1000000 ||
        (uint64_t) source->Xsize * source->Ysize > 512ULL * 1024 * 1024) {
        vips_error("pocketmanga", "image dimensions exceed decoder limit");
        g_object_unref(source); return NULL;
    }
    int result = vips_autorot(source, &image, NULL);
    g_object_unref(source);
    return result ? NULL : image;
}

int pmi_probe(const char *path, int *width, int *height) {
    vips_error_clear();
    VipsImage *image = oriented(path, 1);
    if (!image) return -1;
    *width = image->Xsize; *height = image->Ysize;
    g_object_unref(image);
    return 0;
}

void *pmi_open(const char *path, double scale, int *width, int *height) {
    VipsImage *source = NULL, *sized = NULL, *rgb = NULL;
    VipsImage *flat = NULL, *gray = NULL, *bytes = NULL, *cached = NULL;
    Page *page = NULL;
    vips_error_clear();
    if (!isfinite(scale) || scale <= 0 || scale > 4096) {
        vips_error("pocketmanga", "invalid image scale"); return NULL;
    }
    source = oriented(path, 1);
    if (!source) goto done;
    double output_width = source->Xsize * scale, output_height = source->Ysize * scale;
    if (output_width > 1000000 || output_height > 1000000 ||
        output_width * output_height > 512.0 * 1024 * 1024) {
        vips_error("pocketmanga", "resized dimensions exceed decoder limit"); goto done;
    }
    const char *loader = vips_foreign_find_load(path);
    if (!loader) goto done;
    if ((strcmp(loader, "VipsForeignLoadWebpFile") == 0 ||
         strcmp(loader, "VipsForeignLoadHeifFile") == 0 ||
         strcmp(loader, "VipsForeignLoadJxlFile") == 0 ||
         strcmp(loader, "VipsForeignLoadNsgifFile") == 0 ||
         strcmp(loader, "VipsForeignLoadJp2kFile") == 0) &&
        (uint64_t) source->Xsize * source->Ysize > 32ULL * 1024 * 1024) {
        vips_error("pocketmanga", "full-frame decoder exceeds 32-megapixel budget"); goto done;
    }
    int target_width = (int) fmax(1, round(output_width));
    int target_height = (int) fmax(1, round(output_height));
    int shrink = 1;
    while (shrink < 8 && scale * (shrink * 2) <= 1) shrink *= 2;
    if (shrink > 1 && (strcmp(loader, "VipsForeignLoadJpegFile") == 0 ||
                       strcmp(loader, "VipsForeignLoadWebpFile") == 0)) {
        g_object_unref(source); source = oriented(path, shrink);
        if (!source) goto done;
    }
    double scale_x = (double) target_width / source->Xsize;
    double scale_y = (double) target_height / source->Ysize;
    if (vips_colourspace(source, &rgb, VIPS_INTERPRETATION_sRGB, NULL)) goto done;
    if (vips_image_hasalpha(rgb)) {
        double white[] = {255, 255, 255};
        VipsArrayDouble *background = vips_array_double_new(white, 3);
        int result = vips_flatten(rgb, &flat, "background", background, NULL);
        vips_area_unref((VipsArea *) background);
        if (result) goto done;
    } else flat = g_object_ref(rgb);
    if (vips_resize(flat, &sized, scale_x, "vscale", scale_y, "kernel", VIPS_KERNEL_LANCZOS3, NULL)) goto done;
    if (vips_colourspace(sized, &gray, VIPS_INTERPRETATION_B_W, NULL)) goto done;
    if (vips_cast(gray, &bytes, VIPS_FORMAT_UCHAR, NULL)) goto done;
    /* Demand-driven tiles avoid materializing tall or wide resized pages. */
    if (vips_tilecache(bytes, &cached, "tile_width", 256, "tile_height", 256,
        "max_tiles", 32, "threaded", FALSE, "persistent", TRUE, NULL)) goto done;
    page = g_new0(Page, 1);
    page->image = cached; cached = NULL;
    *width = page->image->Xsize; *height = page->image->Ysize;
done:
    VIPS_UNREF(cached); VIPS_UNREF(bytes); VIPS_UNREF(gray);
    VIPS_UNREF(flat); VIPS_UNREF(rgb); VIPS_UNREF(sized); VIPS_UNREF(source);
    return page;
}

int pmi_region(void *handle, int x, int y, int width, int height,
               uint8_t *pixels, size_t stride) {
    Page *page = handle;
    vips_error_clear();
    if (!page || !pixels || x < 0 || y < 0 || width <= 0 || height <= 0 ||
        width > page->image->Xsize || height > page->image->Ysize ||
        x > page->image->Xsize - width || y > page->image->Ysize - height ||
        stride < (size_t) width || stride > SIZE_MAX / (size_t) height) {
        vips_error("pocketmanga", "invalid image region"); return -1;
    }
    VipsRect rect = {x, y, width, height};
    VipsRegion *region = vips_region_new(page->image);
    if (vips_region_prepare(region, &rect)) { g_object_unref(region); return -1; }
    for (int row = 0; row < height; ++row)
        memcpy(pixels + row * stride,
            VIPS_REGION_ADDR(region, x, y + row), width);
    g_object_unref(region);
    return 0;
}
void pmi_close(void *handle) {
    Page *page = handle;
    if (page) { VIPS_UNREF(page->image); g_free(page); }
}
const char *pmi_error(void) { return vips_error_buffer(); }
