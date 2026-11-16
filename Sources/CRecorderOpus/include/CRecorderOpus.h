#ifndef C_RECORDER_OPUS_H
#define C_RECORDER_OPUS_H
#include <stdint.h>
void *cr_opus_create(void);
void cr_opus_destroy(void *decoder);
int cr_opus_decode(void *decoder, const unsigned char *packet, int length, int16_t *pcm, int capacity, uint32_t *range);
int cr_opus_packet_samples(const unsigned char *packet, int length);
int cr_opus_packet_channels(const unsigned char *packet);
#endif
