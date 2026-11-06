#ifndef CPulseRing_h
#define CPulseRing_h

#include <CoreAudio/AudioHardware.h>
#include <stddef.h>

typedef struct PulseRing PulseRing;

// 创建和释放固定容量的单写单读环，调用者在音频回调停止后释放。
PulseRing * _Nullable PulseRingCreate(void);
void PulseRingDestroy(PulseRing * _Nonnull ring);

// 输入：Tap 返回的 Float32 PCM。输出：环内追加单声道样本，不等待消费者。
void PulseRingPushAudio(PulseRing * _Nonnull ring, const AudioBufferList * _Nonnull input);

OSStatus PulseRingAudioIO(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context);

// 输入：单声道样本；供合成信号测试和基准使用。
void PulseRingPushMono(PulseRing * _Nonnull ring, const float * _Nonnull input, size_t frames);

// 取最新窗口；新样本不足时沿用 destination 的上一窗尾部，返回新增样本数。
size_t PulseRingReadLatest(PulseRing * _Nonnull ring, float * _Nonnull destination, size_t count);

#endif
