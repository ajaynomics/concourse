# /auth.md is the guide an agent, or the harness someone builds for it, reads
# to connect: discovery, sign-in, the three interfaces and how to use them
# well. /llms.txt (llmstxt.org) indexes it with the machine documents. The
# facts it points at stay in the standard metadata (RFC 9728, RFC 8414),
# which is the source of truth. Served only from Concourse's own origin, so no
# third party can hand agents sign-in steps.
class AgentGuidesController < ActionController::API
  include NotAVisit
  # ActionController::API renders no templates by itself; these are Markdown views.
  include ActionView::Rendering

  before_action { expires_in 5.minutes, public: true }

  # llms.txt is Markdown by convention, but served as plain text: that is
  # what the .txt name promises a browser or a fetch tool.
  def index
    render :index, content_type: "text/plain"
  end

  def show
    render :show, content_type: "text/markdown"
  end
end
