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
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Aswin Subhash' => 'https://github.com/aswinsubhash' }
  s.source           = { :git => 'https://github.com/aswinsubhash/native_feed_player.git', :tag => "v#{s.version}" }
  s.documentation_url = 'https://pub.dev/packages/native_feed_player'
  s.source_files = 'native_feed_player/Sources/native_feed_player/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Re-audit the privacy manifest if cache metadata access changes.
  s.resource_bundles = {'native_feed_player_privacy' => ['native_feed_player/Sources/native_feed_player/PrivacyInfo.xcprivacy']}
end
