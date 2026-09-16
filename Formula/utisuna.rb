class Utisuna < Formula
  desc 'Set the default app for the content type of a sample file'
  homepage 'https://github.com/rioriost/utisuna'
  url 'https://github.com/rioriost/utisuna/releases/download/0.1.1/utisuna-0.1.1-macos.zip'
  sha256 '60d7b5132d845d26ade72218130f842cd3e7cef29c800c5685d80f0506120d37'
  version '0.1.1'

  depends_on arch: :arm64
  depends_on macos: :monterey

  def install
    bin.install 'utisuna' => 'utisuna'
  end

  test do
    assert_match 'Set the default app for the content type of a sample file',
                 shell_output("#{bin}/utisuna --help")
  end
end
