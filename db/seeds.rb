# The default organization serves the routes with no organization in the
# path. The system user holds built-in agents such as concourse/conformance,
# and both live there. Idempotent: slug and handles are unique.
Organization.default
User.system
A2a::Conformance.ensure!
# tenancy-ok: isolated v3 seeds provision a deterministic responder per tenant.
Organization.find_each { |organization| A2a::Network.ensure!(organization) } if Concourse.v3?
