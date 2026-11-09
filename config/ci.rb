# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap-audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: Rails", "bin/rails test"
  # Production initializers only run their configured branches when a secret is
  # present (a GlitchTip DSN, for instance), which no test sets. Booting the
  # production environment with a DSN catches a boot failure before a deploy's
  # health check does.
  step "Boot: production", "env SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production GLITCHTIP__DSN=https://key@glitchtip.invalid/1 APP__URL=https://concourse.example.com bin/rails runner 'abort(\"GlitchTip not initialized\") unless Sentry.initialized?'"
  step "Boot: v3 production", "env SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production CONCOURSE__RELEASE_LINE=3 GLITCHTIP__DSN=https://key@glitchtip.invalid/1 APP__URL=https://concourse.example.com bin/rails runner 'abort(\"Wrong release line\") unless Concourse.v3?; abort(\"Native relay activated\") if Agent.native_relay_complete?; abort(\"GlitchTip not initialized\") unless Sentry.initialized?'"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
  # Disposable conformance servers must not depend on io_uring allocation
  # capacity on a shared runner. Select is io-event's portable backend;
  # keep production boot checks and deployed Falcon on their normal selector.
  step "Tests: A2A TCK", "env IO_EVENT_SELECTOR=Select bin/a2a-tck"
  step "Tests: v3 Seeds", "env RAILS_ENV=test CONCOURSE__RELEASE_LINE=3 bin/rails db:seed:replant"
  step "Tests: v3 A2A TCK", "env IO_EVENT_SELECTOR=Select CONCOURSE__RELEASE_LINE=3 bin/a2a-tck"

  # Its own step, never folded into "Tests: Rails": `bin/rails test test/`
  # would pull test/system into that parallelized run, where the browser tests
  # flake on visibility assertions that pass every time under this command.
  # Leaving it out of the checklist let main go red unseen, so it runs here
  # and in the CI workflow, which runs exactly `bin/ci`.
  # Disposable browser-test Falcon servers can exhaust shared io_uring memory.
  # Select keeps that test dependency local; production boot/servers stay native.
  step "Tests: System", "env IO_EVENT_SELECTOR=Select bin/rails test:system"

  # Current client qualification belongs to concourse-clients/bin/ci. This
  # server consumes only the pinned immutable Muse distribution, offline.
  step "Integrity: client release assets", "ruby script/check-client-assets"
end
