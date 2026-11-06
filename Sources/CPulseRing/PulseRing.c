#include "CPulseRing.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { Capacity = 32768, Mask = Capacity - 1 }; // 48 kHz 下缓存约 0.68 秒。
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");

struct PulseRing {
    _Atomic uint64_t written;
    char producerPadding[64]; // 避免读写游标争用同一缓存行。
    _Atomic uint64_t read;
    float samples[Capacity];
};

PulseRing *PulseRingCreate(void) {
    PulseRing *ring = calloc(1, sizeof(*ring));
    if (ring) {
        atomic_init(&ring->written, 0);
        atomic_init(&ring->read, 0);
    }
    return ring;
}

void PulseRingDestroy(PulseRing *ring) { free(ring); }

/*
 * 预留当前可写的帧数；空间不足时丢弃超出的新样本，避免覆盖读取中的帧。
 * 输入：环、请求帧数。输出：写入起点与可写帧数。
 */
static size_t reserve(PulseRing *ring, size_t frames, uint64_t *start) {
    *start = atomic_load_explicit(&ring->written, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    const size_t space = Capacity - (size_t)(*start - read);
    return frames < space ? frames : space;
}

void PulseRingPushMono(PulseRing *ring, const float *input, size_t frames) {
    uint64_t start;
    const size_t count = reserve(ring, frames, &start);
    const size_t offset = (size_t)(start & Mask);
    const size_t first = count < Capacity - offset ? count : Capacity - offset;
    memcpy(ring->samples + offset, input, first * sizeof(float));
    memcpy(ring->samples, input + first, (count - first) * sizeof(float));
    atomic_store_explicit(&ring->written, start + count, memory_order_release);
}

void PulseRingPushAudio(PulseRing *ring, const AudioBufferList *input) {
    if (!input->mNumberBuffers) return;
    const AudioBuffer *left = &input->mBuffers[0];
    const float *a = left->mData;
    if (!a || !left->mNumberChannels) return;
    const size_t channels = left->mNumberChannels;
    size_t frames = left->mDataByteSize / (sizeof(float) * channels);
    const float *b = NULL;
    size_t strideB = channels;
    if (channels > 1) {
        b = a + 1;
    } else if (input->mNumberBuffers > 1) {
        const AudioBuffer *right = &input->mBuffers[1];
        if (right->mData && right->mNumberChannels) {
            b = right->mData;
            strideB = right->mNumberChannels;
            const size_t rightFrames = right->mDataByteSize / (sizeof(float) * strideB);
            if (rightFrames < frames) frames = rightFrames;
        }
    }
    if (!b) {
        PulseRingPushMono(ring, a, frames);
        return;
    }
    float leftPower = 0, rightPower = 0, sumPower = 0;
    for (size_t i = 0; i < frames; i += 8) {
        const float l = a[i * channels], r = b[i * strideB];
        leftPower += l * l;
        rightPower += r * r;
        sumPower += (l + r) * (l + r);
    }
    // 整块接近反相时取更强的声道；常规音频保持线性混合。
    const int cancels = sumPower < 0.0625f * (leftPower + rightPower);
    const float leftGain = cancels ? (leftPower >= rightPower ? 1 : 0) : 0.5f;
    const float rightGain = cancels ? 1 - leftGain : 0.5f;
    uint64_t start;
    const size_t count = reserve(ring, frames, &start);
    for (size_t i = 0; i < count; ++i) {
        ring->samples[(start + i) & Mask] = a[i * channels] * leftGain + b[i * strideB] * rightGain;
    }
    atomic_store_explicit(&ring->written, start + count, memory_order_release);
}

OSStatus PulseRingAudioIO(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output,
    const AudioTimeStamp *outputTime, void *context) {
    if (context) PulseRingPushAudio(context, input);
    return 0;
}

size_t PulseRingReadLatest(PulseRing *ring, float *destination, size_t count) {
    const uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    const uint64_t end = atomic_load_explicit(&ring->written, memory_order_acquire);
    const size_t available = (size_t)(end - read);
    const size_t take = available < count ? available : count;
    if (!take) return 0;
    if (take < count) memmove(destination, destination + take, (count - take) * sizeof(float));
    const size_t offset = (size_t)((end - take) & Mask);
    const size_t first = take < Capacity - offset ? take : Capacity - offset;
    memcpy(destination + count - take, ring->samples + offset, first * sizeof(float));
    memcpy(destination + count - take + first, ring->samples, (take - first) * sizeof(float));
    atomic_store_explicit(&ring->read, end, memory_order_release);
    return take;
}
