class Utisuna < Formula
  desc 'Set the default app for the content type of a sample file'
  homepage 'https://github.com/rioriost/utisuna'
  url 'https://github.com/rioriost/utisuna/releases/download/0.1.0/utisuna-0.1.0-macos.zip'
  sha256 '1fd30abf92b1c4382a467dd5c41341e22fa63eeae1240748a7837e617c446251'
  version '0.1.0'

  def install
    bin.install "utisuna-#{version}-macos/utisuna" => 'utisuna'
  end

  test do
    assert_match 'Set the default app for the content type of a sample file',
                 shell_output("#{bin}/utisuna --help")
  end
end
