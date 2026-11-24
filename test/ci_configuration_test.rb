require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "fileutils"
require "yaml"

class CiConfigurationTest < Minitest::Test
  def test_only_disposable_tck_and_system_servers_use_the_portable_selector
    capture = <<~RUBY
      require "json"
      module CI
        def self.run(&block)
          recorder = Object.new
          def recorder.step(name, command)
            (@steps ||= []) << [name, command]
          end
          recorder.instance_eval(&block)
          puts JSON.generate(recorder.instance_variable_get(:@steps))
        end
      end
      load ARGV.fetch(0)
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", capture, File.expand_path("../config/ci.rb", __dir__))
    assert status.success?, error
    steps = JSON.parse(output).to_h
    expected = {
      "Tests: A2A TCK" => %w[env IO_EVENT_SELECTOR=Select bin/a2a-tck],
      "Tests: v3 A2A TCK" => %w[env IO_EVENT_SELECTOR=Select CONCOURSE__RELEASE_LINE=3 bin/a2a-tck],
      "Tests: System" => %w[env IO_EVENT_SELECTOR=Select bin/rails test:system]
    }
    expected.each do |name, command|
      assert_equal command, Shellwords.split(steps.fetch(name)), name
    end
    steps.except(*expected.keys).each do |name, command|
      refute_includes command, "IO_EVENT_SELECTOR", name
    end
  end

  def test_browser_resolution_failure_keeps_diagnostics_and_exit_status
    prepare_browser(exit_status: 65) do |output, error, status, environment, calls|
      assert_equal 65, status.exitstatus
      assert_includes output + error, "synthetic driver download failure"
      assert_empty environment
      assert_equal 1, calls.size
    end
  end

  def test_browser_setup_exports_and_reports_the_exact_resolved_pair
    prepare_browser do |output, error, status, environment, calls, browser, driver|
      assert status.success?, output + error
      assert_equal [ %w[--browser chrome --browser-version 157.0.8103.78 --driver-version 157.0.8103.78 --force-browser-download --skip-driver-in-path --language-binding ruby --output json] ], calls
      assert_includes environment, "CHROME_BIN=#{browser}\n"
      assert_includes environment, "SE_CHROMEDRIVER=#{driver}\n"
      assert_includes environment, "SE_OFFLINE=true\n"
      assert_includes output, "Chrome for Testing and chromedriver: 157.0.8103.78"
    end
  end

  def test_browser_setup_rejects_an_unpinned_browser_or_driver
    [ { browser_version: "158.0.8117.12" }, { driver_version: "157.0.8103.77" } ].each do |versions|
      prepare_browser(**versions) do |_output, _error, status, environment, calls|
        refute status.success?, versions.inspect
        assert_empty environment
        assert_equal 1, calls.size
      end
    end
  end

  private

  def prepare_browser(exit_status: 0, browser_version: "157.0.8103.78", driver_version: "157.0.8103.78")
    workflow = YAML.load_file(File.expand_path("../.github/workflows/ci.yml", __dir__))
    script = workflow.fetch("jobs").fetch("ci").fetch("steps").find { |step| step["name"] == "Prepare browser driver" }.fetch("run")
    Dir.mktmpdir("concourse-browser-setup") do |dir|
      bin = File.join(dir, "bin")
      gem_dir = File.join(dir, "gem")
      FileUtils.mkdir_p([ bin, File.join(gem_dir, "bin/linux") ])
      browser = File.join(bin, "synthetic-browser")
      driver = File.join(bin, "synthetic-driver")
      File.write(browser, "#!/bin/sh\nprintf 'Google Chrome for Testing %s \\n' #{Shellwords.escape(browser_version)}\n")
      File.write(driver, "#!/bin/sh\nprintf 'ChromeDriver %s (synthetic)\\n' #{Shellwords.escape(driver_version)}\n")
      File.chmod(0o755, browser, driver)
      File.write(File.join(bin, "bundle"), "#!/bin/sh\nprintf '%s\\n' #{Shellwords.escape(gem_dir)}\n")
      File.chmod(0o755, File.join(bin, "bundle"))
      manager = File.join(gem_dir, "bin/linux/selenium-manager")
      File.write(manager, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MANAGER_CALLS\"\nprintf '%s\\n' \"$MANAGER_JSON\"\nexit \"$MANAGER_EXIT\"\n")
      File.chmod(0o755, manager)
      env_file = File.join(dir, "environment")
      calls_file = File.join(dir, "calls")
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GITHUB_ENV" => env_file,
        "MANAGER_CALLS" => calls_file, "MANAGER_EXIT" => exit_status.to_s,
        "MANAGER_JSON" => JSON.generate(logs: [ { message: "synthetic driver download failure" } ], result: { browser_path: browser, driver_path: driver }) }
      output, error, status = Open3.capture3(env, "bash", "-c", script, chdir: dir)
      calls = File.readlines(calls_file).map { |line| Shellwords.split(line) }
      yield output, error, status, File.exist?(env_file) ? File.read(env_file) : "", calls, browser, driver
    end
  end
end
