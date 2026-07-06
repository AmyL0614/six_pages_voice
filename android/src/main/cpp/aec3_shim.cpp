// aec3_shim.cpp
//
// Thin JNI bridge between the Kotlin plugin and WebRTC's AudioProcessing
// module (AEC3). Kotlin owns capture + playback; this shim owns ONLY the
// echo cancellation.
//
// Contract exposed to Kotlin (three operations):
//   nativeCreate()                       -> long handle   (APM with AEC3 on)
//   nativeProcessRender(handle, byte[])  -> void          (feed Joe / far-end)
//   nativeProcessCapture(handle, byte[]) -> void          (clean mic in place)
//   nativeDestroy(handle)                -> void
//
// Audio contract: PCM16, 16 kHz, mono. Kotlin hands 640-byte frames
// (= 320 samples = 20 ms). AEC3 processes 10 ms frames (= 160 samples),
// so each 20 ms frame is split into two 10 ms halves here, invisibly to
// Kotlin. ProcessStream cleans the near-end buffer IN PLACE.

#include <jni.h>
#include <android/log.h>
#include <cstdint>
#include <cstring>
#include <memory>

#include "modules/audio_processing/include/audio_processing.h"

#define LOG_TAG "SixPagesVoiceAEC3"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kSampleRateHz = 16000;
constexpr int kNumChannels  = 1;
constexpr int kFrame10msSamples = 160;   // 10 ms @ 16 kHz
constexpr int kFrame10msBytes   = kFrame10msSamples * 2;  // int16

// Holds one APM instance plus the stream configs it needs.
struct Aec3Engine {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream_config{kSampleRateHz, kNumChannels};
};

// Process one 10 ms half. is_render == true feeds the far-end reference;
// false cleans the near-end capture buffer in place.
inline void ProcessHalf(Aec3Engine* eng, int16_t* pcm, bool is_render) {
  if (is_render) {
    eng->apm->ProcessReverseStream(
        pcm, eng->stream_config, eng->stream_config, pcm);
  } else {
    eng->apm->ProcessStream(
        pcm, eng->stream_config, eng->stream_config, pcm);
  }
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_sixpages_six_1pages_1voice_SixPagesVoicePlugin_nativeCreate(
    JNIEnv* /*env*/, jobject /*thiz*/) {
  auto* eng = new Aec3Engine();
  eng->apm = webrtc::AudioProcessingBuilder().Create();
  if (eng->apm == nullptr) {
    LOGW("AudioProcessingBuilder().Create() returned null");
    delete eng;
    return 0;
  }

  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;         // AEC3 on
  config.echo_canceller.mobile_mode = false;    // full AEC3, not the mobile AECM
  config.high_pass_filter.enabled = true;       // helps the canceller
  config.noise_suppression.enabled = true;      // replaces the old NoiseSuppressor
  eng->apm->ApplyConfig(config);

  LOGI("AEC3 engine created: echo_canceller.enabled=true, mobile_mode=false");
  return reinterpret_cast<jlong>(eng);
}

JNIEXPORT void JNICALL
Java_com_sixpages_six_1pages_1voice_SixPagesVoicePlugin_nativeProcessRender(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jbyteArray frame) {
  auto* eng = reinterpret_cast<Aec3Engine*>(handle);
  if (eng == nullptr) return;

  jsize len = env->GetArrayLength(frame);
  jbyte* bytes = env->GetByteArrayElements(frame, nullptr);
  auto* pcm = reinterpret_cast<int16_t*>(bytes);

  // Walk the buffer in 10 ms halves.
  int offset_samples = 0;
  int total_samples = len / 2;
  while (offset_samples + kFrame10msSamples <= total_samples) {
    ProcessHalf(eng, pcm + offset_samples, /*is_render=*/true);
    offset_samples += kFrame10msSamples;
  }

  // Render frames are the reference only; we do not write changes back.
  env->ReleaseByteArrayElements(frame, bytes, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_com_sixpages_six_1pages_1voice_SixPagesVoicePlugin_nativeProcessCapture(
    JNIEnv* env, jobject /*thiz*/, jlong handle, jbyteArray frame) {
  auto* eng = reinterpret_cast<Aec3Engine*>(handle);
  if (eng == nullptr) return;

  jsize len = env->GetArrayLength(frame);
  jbyte* bytes = env->GetByteArrayElements(frame, nullptr);
  auto* pcm = reinterpret_cast<int16_t*>(bytes);

  int offset_samples = 0;
  int total_samples = len / 2;
  while (offset_samples + kFrame10msSamples <= total_samples) {
    ProcessHalf(eng, pcm + offset_samples, /*is_render=*/false);
    offset_samples += kFrame10msSamples;
  }

  // Capture was cleaned in place; write the changes back to the Java array.
  env->ReleaseByteArrayElements(frame, bytes, 0);
}

JNIEXPORT void JNICALL
Java_com_sixpages_six_1pages_1voice_SixPagesVoicePlugin_nativeDestroy(
    JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
  auto* eng = reinterpret_cast<Aec3Engine*>(handle);
  delete eng;  // scoped_refptr releases the APM
}

}  // extern "C"
