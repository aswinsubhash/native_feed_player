#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint native_feed_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'native_feed_player'
  s.version          = '0.1.0'
  s.summary          = 'Native video playback for scrollable Flutter feeds.'
  s.description      = <<-DESC
Feed-oriented video playback backed by AVPlayer on iOS and Media3 ExoPlayer on
Android, with direction-aware prebuffering, disk caching, player pooling, and
playback quality metrics.
                       DESC
  s.homepage         = 'https://github.com/aswinsubhash/native_feed_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Aswin Subhash' => 'https://github.com/aswinsubhash' }
  s.source           = { :http => 'https://github.com/aswinsubhash/native_feed_player' }
  s.documentation_url = 'https://pub.dev/packages/native_feed_player'
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # The manifest ships even though its arrays are empty, because App Store
  # submission expects one from every bundled framework. Audited against the
  # media cache: it uses ordinary file I/O and per-file size lookups, none of
  # which are required-reason APIs. Re-audit if the cache starts reading free
  # disk space or file timestamps.
  s.resource_bundles = {'native_feed_player_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
