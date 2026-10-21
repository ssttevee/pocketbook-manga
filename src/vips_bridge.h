#ifndef POCKETMANGA_IMAGE_H
#define POCKETMANGA_IMAGE_H
#include <stddef.h>
#include <stdint.h>
/* Calls for a handle must be serialized; regions are local to each call. Output is 8-bit gray. */
int pmi_init(void);
int pmi_probe(const char *path, int *width, int *height);
void *pmi_open(const char *path, double scale, int *width, int *height);
int pmi_region(void *handle, int x, int y, int width, int height,
               uint8_t *pixels, size_t stride);
void pmi_close(void *handle);
const char *pmi_error(void);
#endif
