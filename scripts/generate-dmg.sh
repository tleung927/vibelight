# This script requires create-dmg to be installed from https://github.com/sindresorhus/create-dmg
BUILD_CONFIG=$1

fail()
{
	echo "$1" 1>&2
	exit 1
}

if [ "$BUILD_CONFIG" != "Debug" ] && [ "$BUILD_CONFIG" != "Release" ]; then
  fail "Invalid build configuration - expected 'Debug' or 'Release'"
fi

BUILD_ROOT=$PWD/build
SOURCE_ROOT=$PWD
BUILD_FOLDER=$BUILD_ROOT/build-$BUILD_CONFIG
INSTALLER_FOLDER=$BUILD_ROOT/installer-$BUILD_CONFIG

if [ -n "$CI_VERSION" ]; then
  VERSION=$CI_VERSION
else
  VERSION=`cat $SOURCE_ROOT/app/version.txt`
fi

if [ "$SIGNING_PROVIDER_SHORTNAME" == "" ]; then
  SIGNING_PROVIDER_SHORTNAME=$SIGNING_IDENTITY
fi
if [ "$SIGNING_IDENTITY" == "" ]; then
  SIGNING_IDENTITY=$SIGNING_PROVIDER_SHORTNAME
fi

[ "$SIGNING_IDENTITY" == "" ] || git diff-index --quiet HEAD -- || fail "Signed release builds must not have unstaged changes!"

echo Updating dependencies
# SKIP_DEPS=1 reuses an existing libs/mac (for example after a manual download)
if [ -z "$SKIP_DEPS" ]; then
  python3 $SOURCE_ROOT/setup-deps.py || fail "Dependency download failed!"
fi
[ -d $SOURCE_ROOT/libs/mac/include/openssl ] || fail "libs/mac is missing; run setup-deps.py"

echo Cleaning output directories
rm -rf $BUILD_FOLDER
rm -rf $INSTALLER_FOLDER
mkdir $BUILD_ROOT
mkdir $BUILD_FOLDER
mkdir $INSTALLER_FOLDER

# Enable LTO for official builds
export CFLAGS=-flto=thin
export CXXFLAGS=-flto=thin
export LDFLAGS=-flto=thin

echo Configuring the project
pushd $BUILD_FOLDER
# Universal by default; set MAC_ARCHS=arm64 when building against an
# arm64-only Qt such as Homebrew's.
qmake $SOURCE_ROOT/moonlight-qt.pro QMAKE_APPLE_DEVICE_ARCHS="${MAC_ARCHS:-x86_64 arm64}" || fail "Qmake failed!"
popd

echo Compiling Moonlight in $BUILD_CONFIG configuration
pushd $BUILD_FOLDER
make -j$(sysctl -n hw.logicalcpu) $(echo "$BUILD_CONFIG" | tr '[:upper:]' '[:lower:]') || fail "Make failed!"
popd

echo Saving dSYM file
pushd $BUILD_FOLDER
dsymutil app/Moonlight.app/Contents/MacOS/Moonlight -o Moonlight-$VERSION.dsym || fail "dSYM creation failed!"
cp -R Moonlight-$VERSION.dsym $INSTALLER_FOLDER || fail "dSYM copy failed!"
popd

echo Creating app bundle
EXTRA_ARGS=
if [ "$BUILD_CONFIG" == "Debug" ]; then EXTRA_ARGS="$EXTRA_ARGS -use-debug-libs"; fi
echo Extra deployment arguments: $EXTRA_ARGS
macdeployqt $BUILD_FOLDER/app/Moonlight.app $EXTRA_ARGS -qmldir=$SOURCE_ROOT/app/gui -appstore-compliant || fail "macdeployqt failed!"

# Homebrew Qt ships optional plugins (PDF, 3D, virtual keyboard, ...) whose
# frameworks are not installed, so macdeployqt copies them without their
# dependencies. The app never loads them; drop any plugin with an unresolved
# @rpath dependency, then the QML module folders left with dangling links.
echo Removing plugins with missing dependencies
CONTENTS=$BUILD_FOLDER/app/Moonlight.app/Contents
find "$CONTENTS/PlugIns" -name '*.dylib' | while read -r plugin; do
  for dep in $(otool -L "$plugin" | tail -n +2 | awk '{print $1}' | grep '^@rpath/'); do
    if [ ! -e "$CONTENTS/Frameworks/${dep#@rpath/}" ]; then
      echo "  $plugin"
      rm -f "$plugin"
      break
    fi
  done
done
find "$CONTENTS" -type l ! -exec test -e {} \; -print | xargs -n1 dirname | sort -u | while read -r dir; do
  rm -rf "$dir"
done

# Apple bundle versions remain numeric; nightly identity and source are explicit.
if [[ "$VERSION" =~ ^6\.[12]\.0-daily\.([1-9][0-9]*)$ ]]; then
  NIGHTLY_SEQUENCE="${BASH_REMATCH[1]}"
  NIGHTLY_SOURCE=$(git rev-parse HEAD) || fail "Could not resolve nightly source"
  PLIST="$BUILD_FOLDER/app/Moonlight.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 6.2.$NIGHTLY_SEQUENCE" "$PLIST" || fail "Could not set nightly bundle version"
  /usr/libexec/PlistBuddy -c "Add :MoonlightNightlyVersion string $VERSION" "$PLIST" || fail "Could not set nightly identity"
  /usr/libexec/PlistBuddy -c "Add :MoonlightSourceCommit string $NIGHTLY_SOURCE" "$PLIST" || fail "Could not set nightly source"
fi

echo Removing dSYM files from app bundle
find $BUILD_FOLDER/app/Moonlight.app/ -name '*.dSYM' | xargs rm -rf

# Vibelight: ship the bundle as Vibelight.app. The executable inside stays
# "Moonlight" (CFBundleExecutable), so the steps above are unchanged.
echo Renaming app bundle to Vibelight.app
rm -rf $BUILD_FOLDER/app/Vibelight.app
mv $BUILD_FOLDER/app/Moonlight.app $BUILD_FOLDER/app/Vibelight.app || fail "Bundle rename failed!"
APP_BUNDLE=$BUILD_FOLDER/app/Vibelight.app

if [ "$SIGNING_IDENTITY" != "" ]; then
  echo Signing app bundle
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" $APP_BUNDLE || fail "Signing failed!"
else
  # Seal the app and its non-Qt dependencies after all metadata and resource
  # edits. Deployment-time ad hoc signatures may be stale or incomplete. This
  # is not a Developer ID signature and does not make the nightly notarized.
  echo Ad-hoc signing completed app bundle
  codesign --force --deep --sign - "$APP_BUNDLE" || fail "Ad-hoc signing failed!"
fi

codesign --verify --deep --strict "$APP_BUNDLE" || fail "App bundle signature verification failed!"

echo Creating DMG
if [ "$SIGNING_IDENTITY" != "" ]; then
  create-dmg $APP_BUNDLE $INSTALLER_FOLDER --identity="$SIGNING_IDENTITY" --no-version-in-filename || fail "create-dmg failed!"
else
  # Unsigned builds use the built-in hdiutil, so they need neither the npm
  # create-dmg (sindresorhus) nor its codesign step. Homebrew's "create-dmg"
  # formula is a different tool with incompatible arguments.
  DMG_STAGE=$BUILD_ROOT/dmg-stage
  rm -rf $DMG_STAGE
  mkdir -p $DMG_STAGE || fail "DMG staging failed!"
  cp -R $APP_BUNDLE $DMG_STAGE/ || fail "DMG staging failed!"
  ln -s /Applications $DMG_STAGE/Applications
  hdiutil create -volname Vibelight -srcfolder $DMG_STAGE -fs HFS+ -format UDZO -ov $INSTALLER_FOLDER/Vibelight.dmg || fail "hdiutil failed!"
  rm -rf $DMG_STAGE
fi

if [ "$NOTARY_KEYCHAIN_PROFILE" != "" ]; then
  echo Uploading to App Notary service
  xcrun notarytool submit --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait $INSTALLER_FOLDER/Vibelight.dmg || fail "Notary submission failed"

  echo Stapling notary ticket to DMG
  xcrun stapler staple -v $INSTALLER_FOLDER/Vibelight.dmg || fail "Notary ticket stapling failed!"
fi

# create-dmg names the image after CFBundleDisplayName (Vibelight)
mv $INSTALLER_FOLDER/Vibelight.dmg $INSTALLER_FOLDER/Vibelight-$VERSION.dmg
echo Build successful
