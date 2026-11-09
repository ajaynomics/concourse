module A2a
  # Requests waiting in next_task, a blocking SendMessage, or a stream. Each
  # is a fiber that re-reads the task twice a second, so the cap bounds that
  # polling rather than any thread pool. When it is full the call returns at
  # once. No organization holds more than a quarter of the slots, so one
  # tenant's waiting agents never shut out another's.
  class Waiters
    DEFAULT_LIMIT = 200
    SHARE = 4

    class << self
      def limit
        @limit || DEFAULT_LIMIT
      end

      def limit=(value)
        @limit = value.nil? ? nil : Integer(value)
      end

      def acquire(organization_id = nil)
        mutex.synchronize do
          return false if count >= limit
          return false if organization_id && held[organization_id] >= share

          self.count = count + 1
          held[organization_id] += 1 if organization_id
          true
        end
      end

      def release(organization_id = nil)
        mutex.synchronize do
          self.count = count - 1 if count.positive?
          if organization_id && held[organization_id].positive?
            held[organization_id] -= 1
            held.delete(organization_id) if held[organization_id].zero?
          end
        end
      end

      def share
        [ (limit / SHARE.to_f).ceil, 1 ].max
      end

      # Sleeps without holding a database connection, so waiting fibers do
      # not starve the pool. Inside a transaction the connection stays.
      def idle(seconds)
        unless ActiveRecord::Base.connection.transaction_open?
          ActiveRecord::Base.connection_pool.release_connection
        end
        sleep(seconds)
      end

      def reset!
        mutex.synchronize do
          self.count = 0
          held.clear
        end
      end

      private

      def count
        @count ||= 0
      end

      def count=(value)
        @count = value
      end

      def held
        @held ||= Hash.new(0)
      end

      def mutex
        @mutex ||= Mutex.new
      end
    end
  end
end
