Pod::Spec.new do |spec|
  spec.name       = "MongoSwiftMobile"
  spec.version    = "0.0.2"
  spec.summary    = "The Swift driver for MongoDB"
  spec.homepage   = "https://github.com/mongodb/mongo-swift-driver"
  spec.license    = 'Apache License, Version 2.0'
  spec.authors    = {
    "Matt Broadstone" => "mbroadst@mongodb.com",
    "Kaitlin Mahar" => "kaitlin.mahar@mongodb.com"
  }
  spec.source     = {
    :git => "https://github.com/mongodb/mongo-swift-driver.git",
    :tag => 'v0.0.2'
  }

  spec.ios.deployment_target = "11.2"
  spec.tvos.deployment_target = "9.1"
  spec.osx.deployment_target = "10.10"

  spec.requires_arc = true
  spec.source_files = "Sources/MongoSwift/**/*.swift"
  spec.prepare_command = 'sh build.sh'
  spec.ios.vendored_frameworks = 'MobileSDKs/iphoneos/libbson.framework', 'MobileSDKs/iphoneos/libmongoc.framework'
end
