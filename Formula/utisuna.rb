class Utisuna < Formula
  desc "Set the default app for the content type of a sample file"
  homepage "https://github.com/rioriost/utisuna"
  url "https://github.com/rioriost/utisuna/releases/download/0.1.3/utisuna-0.1.3-macos.zip"
  sha256 "10cd79be3a8ce3d3398613e100409ac43ce756e307f137ecda5b5c83312ccdf7"
  version "0.1.3"

  depends_on arch: :arm64
  depends_on macos: :monterey

  def install
    bin.install "utisuna"
  end

  test do
    assert_match "Set the default app for the content type of a sample file",
                 shell_output("#{bin}/utisuna --help")
    assert_equal version.to_s, shell_output("#{bin}/utisuna --version").strip
  end
end
