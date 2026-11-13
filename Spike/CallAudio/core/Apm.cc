// Built against the freedesktop.org webrtc-audio-processing release (see build.sh), stock settings:
// the same AEC3 defaults Chrome runs, no Browsa tuning.
#include "Apm.h"
#include "modules/audio_processing/include/audio_processing.h"

namespace browsa {
namespace {
class WebRtcApm : public Apm {
 public:
  explicit WebRtcApm(const ApmOptions& o) {
    apm_ = webrtc::AudioProcessingBuilder().Create();
    webrtc::AudioProcessing::Config c;
    c.pipeline.maximum_internal_processing_rate = 48000;
    c.high_pass_filter.enabled = o.highPass;
    c.echo_canceller.enabled = o.echo;
    c.echo_canceller.mobile_mode = false;
    c.noise_suppression.enabled = o.noise;
    c.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
    c.gain_controller2.enabled = o.gain;
    c.gain_controller2.adaptive_digital.enabled = o.gain;
    c.residual_echo_detector.enabled = true;
    apm_->ApplyConfig(c);
    apm_->Initialize();
  }
  ~WebRtcApm() override { release(apm_); }
  void played(float* f) override {
    const webrtc::StreamConfig sc(48000, 1);
    float* ch[1] = {f};
    apm_->ProcessReverseStream(ch, sc, sc, ch);
  }
  bool process(float* f, int delayHintMs) override {
    const webrtc::StreamConfig sc(48000, 1);
    float* ch[1] = {f};
    apm_->set_stream_delay_ms(delayHintMs);
    return apm_->ProcessStream(ch, sc, sc, ch) == 0;
  }
  ApmStats stats() override {
    const auto s = apm_->GetStatistics(true);
    ApmStats r;
    if (s.echo_return_loss_enhancement) r.erle = *s.echo_return_loss_enhancement;
    if (s.echo_return_loss) r.erl = *s.echo_return_loss;
    if (s.delay_ms) r.delayMs = *s.delay_ms;
    if (s.residual_echo_likelihood) r.residualLikelihood = *s.residual_echo_likelihood;
    return r;
  }
 private:
  // Older releases hand back a raw pointer, newer ones a ref-counted one; cope with both.
  template <class T> static void release(T*& p) { delete p; p = nullptr; }
  template <class T> static void release(T& p) { p = nullptr; }
  decltype(webrtc::AudioProcessingBuilder().Create()) apm_;
};
}  // namespace
Apm* Apm::create(const ApmOptions& o) { return new WebRtcApm(o); }
}  // namespace browsa
