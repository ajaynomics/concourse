# First in the stack, so static files and exception pages get the header too.
Rails.application.config.middleware.insert_before 0, Concourse::NoIndex
