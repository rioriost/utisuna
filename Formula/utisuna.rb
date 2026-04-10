class Utisuna < Formula
  desc 'Set the default app for the content type of a sample file'
  homepage 'https://github.com/rioriost/utisuna'
  url 'https://github.com/rioriost/utisuna/releases/download/0.1.0/utisuna-0.1.0-macos.zip'
  sha256 '835418f20da549c20961a18e6fa6172ed8bebd8ccfe79c975d3df4dc367a7f7d'
  version '0.1.0'

  def install
    bin.install 'utisuna' => 'utisuna'
  end

  test do
    assert_match 'Set the default app for the content type of a sample file',
                 shell_output("#{bin}/utisuna --help")
  end
end
