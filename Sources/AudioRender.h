#pragma once
#include <CoreAudio/CoreAudio.h>

typedef struct VolumeRender VolumeRender;
VolumeRender *volume_create(float gain, double sampleRate);
void volume_destroy(VolumeRender *state);
void volume_set_gain(VolumeRender *state, float gain);
bool volume_has_fault(VolumeRender *state);
void volume_render(VolumeRender *state, const AudioBufferList *input, AudioBufferList *output);
OSStatus volume_register(AudioObjectID device, VolumeRender *state, AudioDeviceIOProcID *io);
