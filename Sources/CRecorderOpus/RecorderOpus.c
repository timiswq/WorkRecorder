#include "CRecorderOpus.h"
#include "opus.h"
#include <stddef.h>

// The archive and live adapters both consume mono PCM at 16 kHz.
static const int sample_rate = 16000;

void *cr_opus_create(void) {
    int error;
    OpusDecoder *decoder = opus_decoder_create(sample_rate, 1, &error);
    return error == OPUS_OK ? decoder : NULL;
}

void cr_opus_destroy(void *decoder) {
    opus_decoder_destroy(decoder);
}

int cr_opus_decode(void *decoder, const unsigned char *packet, int length,
                   int16_t *pcm, int capacity, uint32_t *range) {
    int samples = opus_decode(decoder, packet, length, pcm, capacity, 0);
    if (samples >= 0 && opus_decoder_ctl(decoder, OPUS_GET_FINAL_RANGE(range)) != OPUS_OK) {
        return -1;
    }
    return samples;
}

int cr_opus_packet_samples(const unsigned char *packet, int length) {
    return opus_packet_get_nb_samples(packet, length, sample_rate);
}

int cr_opus_packet_channels(const unsigned char *packet) {
    return opus_packet_get_nb_channels(packet);
}
