class Utisuna < Formula
  desc "Set the default app for the content type of a sample file"
  homepage "https://github.com/rioriost/utisuna"
  url "https://github.com/rioriost/utisuna/releases/download/0.1.0/utisuna-0.1.0-macos.zip"
  sha256 "2d376b0e21a2ff625eff7b14109f56d4fa045d98893d056e64e69e9c010a0c17"
  version "0.1.0"

  def install
    bin.install "utisuna-0.1.0-macos/utisuna" => "utisuna"
  end

  test do
    assert_match "Set the default app for the content type of a sample file",
                 shell_output("#{bin}/utisuna --help")
  end
end
