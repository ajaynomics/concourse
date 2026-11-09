require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
load File.expand_path("../script/check-client-assets", __dir__)

class ClientAssetsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PUBLISHED = {
    "public/connectors/muse/v1/CONNECTOR.md" => "834390562830e399ebfd123df7c120ae83170f38f0818c2d3739c8bc7cbbaaba",
    "public/connectors/muse/v1/connector.yaml" => "f1fd64626cbcfd75c428cb1a1a674b5ba27e1b53fad929dfc8444524fa4b8b0e",
    "public/connectors/muse/v1/bin/concourse.py" => "e474b7f442b25ada8017c8602be8c65cf80deb31cee5406c3c8317740bba463c",
    "public/connectors/muse/v1/SHA256SUMS" => "8affea285e672d13f335d8e058ac77d4f193c8ff5f07000df74a651b81f7eb6b"
  }.freeze

  def test_exact_published_v1_is_retained_from_pinned_client_source
    lock = ClientAssets.verify!(ROOT)
    assert_equal PUBLISHED, lock.fetch("files")
    PUBLISHED.each do |path, digest|
      assert_equal digest, Digest::SHA256.file(File.join(ROOT, path)).hexdigest
    end
  end

  def test_cli_checks_the_server_checkout_without_network
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "script/check-client-assets"))
    assert status.success?, error
    assert_includes output, "Verified 4 client assets"
  end

  def test_corrupted_and_missing_inputs_fail
    with_copy do |root|
      path = File.join(root, ClientAssets::FILES.first)
      File.write(path, "changed")
      assert_raises(RuntimeError) { ClientAssets.verify!(root) }
      File.delete(path)
      assert_raises(RuntimeError) { ClientAssets.verify!(root) }
    end
  end

  def test_symlink_inputs_fail_even_when_their_contents_match
    with_copy do |root|
      path = File.join(root, ClientAssets::FILES.first)
      File.rename(path, "#{path}.original")
      File.symlink("#{path}.original", path)
      assert_raises(RuntimeError) { ClientAssets.verify!(root) }
    end
  end

  def test_unpinned_regular_files_and_hidden_files_fail
    %w[unpinned.py .private-note].each do |name|
      with_copy do |root|
        File.write(File.join(root, "public/connectors/muse/v1", name), "unreviewed")
        assert_raises(RuntimeError) { ClientAssets.verify!(root) }
      end
    end
  end

  def test_unpinned_symlinks_and_empty_directories_fail
    with_copy do |root|
      directory = File.join(root, "public/connectors/muse/v1")
      File.symlink("bin/concourse.py", File.join(directory, "unreviewed.py"))
      assert_raises(RuntimeError) { ClientAssets.verify!(root) }
      File.delete(File.join(directory, "unreviewed.py"))
      Dir.mkdir(File.join(directory, "unreviewed"))
      assert_raises(RuntimeError) { ClientAssets.verify!(root) }
    end
  end

  def test_unexpected_inventory_and_unpinned_sources_fail
    [
      ->(lock) { lock["files"]["../../private"] = "0" * 64 },
      ->(lock) { lock["files"].delete(ClientAssets::FILES.first) },
      ->(lock) { lock["commit"] = "main" },
      ->(lock) { lock["repository"] = "#{ClientAssets::REPOSITORY}.invalid" },
      ->(lock) { lock["release"] = "latest" },
      ->(lock) { lock["schema_version"] = 2 }
    ].each do |change|
      with_copy do |root|
        path = File.join(root, "vendor/concourse-clients.json")
        lock = JSON.parse(File.read(path))
        change.call(lock)
        File.write(path, JSON.generate(lock))
        assert_raises(RuntimeError) { ClientAssets.verify!(root) }
      end
    end
  end

  def test_current_client_source_and_migration_templates_are_no_longer_server_inputs
    %w[pi/concourse-v3/cli.ts script/concourse-v3 adapters/muse/v2/bin/concourse.py
      pi/vendor/pi-140-input-preparation-5f7cade8/manifest.json packaging/clients/manifest.json
      script/export-clients].each { |path| refute File.exist?(File.join(ROOT, path)), path }
    ci = File.read(File.join(ROOT, "config/ci.rb"))
    refute_includes ci, "cd pi/concourse-v3"
    assert_includes ci, "ruby script/check-client-assets"
    workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))
    refute_includes workflow, "pi/concourse-v3/package-lock.json"
  end

  def test_docker_excludes_clients_and_private_worktrees_but_keeps_the_served_assets
    rules = File.readlines(File.join(ROOT, ".dockerignore"), chomp: true)
    %w[/pi/ /adapters/ /packaging/ /.worktrees/ /.evidence/ **/node_modules/].each do |rule|
      assert_includes rules, rule
    end
    refute_includes rules, "/public/"
    refute_includes rules, "/public/connectors/"
    assert File.file?(File.join(ROOT, "JOIN-V3.md"))
    assert_includes File.read(File.join(ROOT, "JOIN-V3.md")), "#{ClientAssets::REPOSITORY}.git"
  end

  private

  def with_copy
    Dir.mktmpdir("client-assets") do |root|
      (ClientAssets::FILES + [ "vendor/concourse-clients.json" ]).each do |path|
        destination = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(ROOT, path), destination)
      end
      yield root
    end
  end
end
