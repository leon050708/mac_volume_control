#include "../Sources/AudioRender.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { UInt32 count; AudioBuffer buffers[2]; } TwoBuffers;
static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.0001f); }

int main(void) {
    float input[] = {0.8f, -0.4f, 0.2f, -0.6f};
    float output[4] = {0};
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    VolumeRender *s = volume_create(0.5f, 48000);
    assert(s);
    volume_render(s, &in, &out);
    for (int i = 0; i < 4; ++i) near(output[i], input[i] * 0.5f);
    assert(!volume_has_fault(s));
    volume_destroy(s);

    // Deinterleave stereo without swapping the channels.
    float left[2], right[2];
    TwoBuffers planar = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    s = volume_create(1, 48000);
    volume_render(s, &in, (AudioBufferList *)&planar);
    near(left[0], 0.8f); near(left[1], 0.2f);
    near(right[0], -0.4f); near(right[1], -0.6f);
    volume_render(s, (AudioBufferList *)&planar, &out);
    for (int i = 0; i < 4; ++i) near(output[i], input[i]);
    volume_destroy(s);

    // Stereo-to-mono uses both channels, mono-to-stereo duplicates.
    float mono[2];
    AudioBufferList monoList = {1, {{1, sizeof(mono), mono}}};
    s = volume_create(1, 48000);
    volume_render(s, &in, &monoList);
    near(mono[0], 0.2f); near(mono[1], -0.2f);
    volume_render(s, &monoList, &out);
    near(output[0], 0.2f); near(output[1], 0.2f);
    near(output[2], -0.2f); near(output[3], -0.2f);
    volume_destroy(s);

    // Muting ramps smoothly to zero, without a discontinuity at a callback boundary.
    float constant[256], ramp[256];
    for (int i = 0; i < 256; ++i) constant[i] = 1;
    AudioBufferList ci = {1, {{1, sizeof(constant), constant}}};
    AudioBufferList co = {1, {{1, sizeof(ramp), ramp}}};
    s = volume_create(1, 48000);
    volume_set_gain(s, 0);
    volume_render(s, &ci, &co);
    assert(ramp[0] < 1 && ramp[0] > 0.99f);
    for (int i = 1; i < 256; ++i) assert(ramp[i] <= ramp[i-1] && ramp[i] >= 0);
    near(ramp[255], 0);
    volume_render(s, &ci, &co);
    for (int i = 0; i < 256; ++i) near(ramp[i], 0);
    volume_destroy(s);

    // A changed/invalid buffer size must produce silence and trip the watchdog.
    s = volume_create(1, 48000);
    out.mBuffers[0].mDataByteSize -= sizeof(float);
    for (int i = 0; i < 4; ++i) output[i] = 42;
    volume_render(s, &in, &out);
    assert(volume_has_fault(s));
    for (int i = 0; i < 3; ++i) near(output[i], 0);
    near(output[3], 42); // Guard beyond the declared output capacity.
    volume_destroy(s);
    puts("PASS: gain, stereo/planar mapping, mono conversion, smooth mute, invalid-buffer guard");
}
