class Api::EventCursorsController < ApiController
  include EventLogApi

  # Acknowledge everything up to and including cursor. Cumulative, monotonic
  # and idempotent: a lower or repeated cursor changes nothing.
  def update
    AgentEvent.acknowledge!(Current.agent, AgentEvent.parse_cursor(params[:cursor]))
    head :no_content
  end
end
