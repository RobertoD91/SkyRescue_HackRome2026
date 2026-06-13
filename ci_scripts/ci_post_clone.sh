#!/bin/sh
set -e

echo "Xcode Cloud post-clone for SkyRescue"
xcodebuild -version
swift --version

if [ ! -d "iOS_App/SkyRescue.xcodeproj" ]; then
  echo "Missing iOS_App/SkyRescue.xcodeproj"
  exit 1
fi

echo "SkyRescue project found"
