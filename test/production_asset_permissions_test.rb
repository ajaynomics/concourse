require "test_helper"
require "fileutils"
require "tmpdir"

class ProductionAssetPermissionsTest < ActiveSupport::TestCase
  test "compiled public assets remain readable after Kamal copies them as root" do
    dockerfile = Rails.root.join("Dockerfile").read
    assert_match(/assets:precompile\s*&&\s*\\\n\s*chmod -R a\+rX public\/assets\b/, dockerfile)
    command = dockerfile[/^\s*(chmod -R a\+rX public\/assets)\s*$/, 1]
    assert command

    Dir.mktmpdir("concourse-public-assets-") do |directory|
      assets = File.join(directory, "public/assets")
      FileUtils.mkdir_p(File.join(assets, "controllers"))
      paths = %w[connection.webp connection.webm connection.mp4 .manifest.json controllers/hero.js].map do |name|
        path = File.join(assets, name)
        File.write(path, "public asset")
        File.chmod(0o600, path)
        path
      end
      File.chmod(0o700, assets, File.join(assets, "controllers"))
      private_file = File.join(directory, "private-source")
      File.write(private_file, "not a real secret")
      File.chmod(0o600, private_file)

      assert system("sh", "-c", command, chdir: directory)

      paths.each do |path|
        assert_equal 0o644, File.stat(path).mode & 0o777, path
        assert_equal "public asset", File.read(path)
      end
      [ assets, File.join(assets, "controllers") ].each do |path|
        assert_equal 0o755, File.stat(path).mode & 0o777, path
      end
      assert_equal 0o600, File.stat(private_file).mode & 0o777
    end
  end
end
