#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint six_pages_voice.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'six_pages_voice'
  s.version          = '0.0.1'
  s.summary          = 'Low-latency ElevenLabs voice with acoustic echo cancellation for Flutter.'
  s.description      = <<-DESC
A Flutter plugin providing a real-time voice pipeline with native acoustic echo
cancellation (AEC3 on Android, VoiceProcessingIO on iOS) for ElevenLabs
Conversational AI. Exposes start, stop, feedPlayback, and a capture stream.
                       DESC
  s.homepage         = 'https://github.com/AmyL0614/six_pages_voice'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Six Pages Studio, LLC' => 'founder@thesixpages.app' }
  s.source           = { :path => '.' }
  s.source_files = 'six_pages_voice/Sources/six_pages_voice/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'six_pages_voice_privacy' => ['six_pages_voice/Sources/six_pages_voice/PrivacyInfo.xcprivacy']}
end
