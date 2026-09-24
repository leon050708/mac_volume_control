#include "AudioRender.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// The HAL callback performs no allocation, Objective-C/Swift calls, locking or logging.
struct VolumeRender {
    _Atomic(float) target;
    _Atomic(bool) fault;
    float current;
    float step;
};

VolumeRender *volume_create(float gain, double sampleRate) {
    VolumeRender *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->target, gain);
    atomic_init(&s->fault, false);
    s->current = gain;
    s->step = 1.0f / (float)(sampleRate * 0.005); // Full-scale transition in 5 ms.
    if (!atomic_is_lock_free(&s->target) || !atomic_is_lock_free(&s->fault)) {
        free(s);
        return NULL;
    }
    return s;
}
void volume_destroy(VolumeRender *s) { free(s); }
void volume_set_gain(VolumeRender *s, float gain) {
    atomic_store_explicit(&s->target, isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 1,
                          memory_order_relaxed);
}
bool volume_has_fault(VolumeRender *s) {
    return atomic_load_explicit(&s->fault, memory_order_relaxed);
}

// Accept either one interleaved buffer or two mono buffers, all Float32.
static bool layout(const AudioBufferList *list, UInt32 *channels, UInt32 *frames) {
    if (!list || list->mNumberBuffers < 1 || list->mNumberBuffers > 2) return false;
    *channels = 0;
    *frames = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        UInt32 n = buffer->mNumberChannels;
        if (n < 1 || n > 2 || !buffer->mData) return false;
        if (buffer->mDataByteSize % (n * sizeof(float))) return false;
        UInt32 count = buffer->mDataByteSize / (n * sizeof(float));
        if (b && count != *frames) return false;
        *frames = count;
        *channels += n;
    }
    return *channels <= 2;
}
static float read_sample(const AudioBufferList *list, UInt32 frame, UInt32 channel) {
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (channel < buffer->mNumberChannels)
            return ((const float *)buffer->mData)[frame * buffer->mNumberChannels + channel];
        channel -= buffer->mNumberChannels;
    }
    return 0;
}
static void write_sample(AudioBufferList *list, UInt32 frame, UInt32 channel, float value) {
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &list->mBuffers[b];
        if (channel < buffer->mNumberChannels) {
            ((float *)buffer->mData)[frame * buffer->mNumberChannels + channel] = value;
            return;
        }
        channel -= buffer->mNumberChannels;
    }
}
void volume_render(VolumeRender *s, const AudioBufferList *input, AudioBufferList *output) {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData)
            memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    UInt32 inChannels, inFrames, outChannels, outFrames;
    if (!layout(input, &inChannels, &inFrames) || !layout(output, &outChannels, &outFrames)
        || inFrames != outFrames) {
        atomic_store_explicit(&s->fault, true, memory_order_relaxed);
        return;
    }
    float target = atomic_load_explicit(&s->target, memory_order_relaxed);
    for (UInt32 f = 0; f < outFrames; ++f) {
        float delta = target - s->current;
        s->current += fminf(s->step, fmaxf(-s->step, delta));
        float left = read_sample(input, f, 0);
        float right = inChannels == 2 ? read_sample(input, f, 1) : left;
        if (outChannels == 1) write_sample(output, f, 0, (left + right) * 0.5f * s->current);
        else {
            write_sample(output, f, 0, left * s->current);
            write_sample(output, f, 1, right * s->current);
        }
    }
}
OSStatus volume_io(AudioObjectID device, const AudioTimeStamp *now,
                   const AudioBufferList *input, const AudioTimeStamp *inputTime,
                   AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    volume_render(context, input, output);
    return noErr;
}
OSStatus volume_register(AudioObjectID device, VolumeRender *state, AudioDeviceIOProcID *io) {
    return AudioDeviceCreateIOProcID(device, volume_io, state, io);
}
