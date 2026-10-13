# The FFmpeg build WallpaperMachine links and bundles.
#
# Homebrew's `ffmpeg@8` is configured with `--enable-gpl --enable-version3
# --enable-openssl`, which makes its libraries GPL-3.0-or-later and links
# Apache-2.0 OpenSSL: neither may be combined with this GPL-2.0-only
# application. This formula keeps LGPL libraries and native codecs, including
# the VideoToolbox encoder used by renderer verification. External codec
# support is limited to BSD-2-Clause dav1d. Auto-detection is disabled so
# unrelated installed packages cannot change the linked dependency set.
# LICENSING.md records the remaining non-FFmpeg distribution blockers.
#
# Install with `python3 scripts/install_ffmpeg.py`.
class MweFfmpeg < Formula
  desc "LGPL FFmpeg libraries for WallpaperMachine"
  homepage "https://ffmpeg.org/"
  url "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz"
  sha256 "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
  license "LGPL-2.1-or-later"

  keg_only "it is a project-specific FFmpeg build and must not shadow Homebrew's ffmpeg"

  depends_on "pkgconf" => :build
  depends_on "nasm" => :build if Hardware::CPU.intel?
  depends_on "dav1d"
  depends_on :macos

  uses_from_macos "bzip2"
  uses_from_macos "zlib"

  def install
    args = %W[
      --prefix=#{prefix}
      --cc=#{ENV.cc}
      --host-cflags=#{ENV.cflags}
      --host-ldflags=#{ENV.ldflags}
      --enable-shared
      --disable-static
      --enable-pthreads
      --disable-autodetect
      --disable-gpl
      --disable-version3
      --disable-nonfree
      --disable-programs
      --disable-doc
      --disable-network
      --disable-devices
      --disable-sdl2
      --disable-libxml2
      --disable-securetransport
      --enable-libdav1d
      --enable-videotoolbox
      --enable-audiotoolbox
    ]
    args << "--enable-neon" if Hardware::CPU.arm?

    system "./configure", *args
    system "make", "install"
  end

  test do
    # The libraries must report the LGPL configuration and the decode/mux path used by the renderer's tests.
    (testpath/"probe.c").write <<~C
      #include <libavcodec/avcodec.h>
      #include <libavformat/avformat.h>
      #include <stdio.h>
      #include <string.h>
      int main(void) {
        if (strstr(avcodec_configuration(), "--enable-gpl") || strstr(avcodec_configuration(), "--enable-version3")) return 1;
        if (!avcodec_find_decoder(AV_CODEC_ID_H264) || !avcodec_find_decoder(AV_CODEC_ID_HEVC) || !avcodec_find_decoder(AV_CODEC_ID_AV1)) return 2;
        if (!avcodec_find_encoder_by_name("h264_videotoolbox")) return 3;
        printf("%s\\n", avcodec_license());
        return 0;
      }
    C
    system ENV.cc, "probe.c", "-I#{include}", "-L#{lib}", "-lavcodec", "-lavformat", "-lavutil", "-o", "probe"
    assert_match "LGPL", shell_output("./probe")
  end
end
