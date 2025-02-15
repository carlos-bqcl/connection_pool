require "timeout"
require_relative "connection_pool/version"

class ConnectionPool
  class Error < ::RuntimeError; end
  class PoolShuttingDownError < ::ConnectionPool::Error; end
  class TimeoutError < ::Timeout::Error; end
end

# Generic connection pool class for sharing a limited number of objects or network connections
# among many threads.  Note: pool elements are lazily created.
#
# Example usage with block (faster):
#
#    @pool = ConnectionPool.new { Redis.new }
#    @pool.with do |redis|
#      redis.lpop('my-list') if redis.llen('my-list') > 0
#    end
#
# Using optional timeout override (for that single invocation)
#
#    @pool.with(timeout: 2.0) do |redis|
#      redis.lpop('my-list') if redis.llen('my-list') > 0
#    end
#
# Example usage replacing an existing connection (slower):
#
#    $redis = ConnectionPool.wrap { Redis.new }
#
#    def do_work
#      $redis.lpop('my-list') if $redis.llen('my-list') > 0
#    end
#
# Accepts the following options:
# - :size - number of connections to pool, defaults to 5
# - :timeout - amount of time to wait for a connection if none currently available, defaults to 5 seconds
#
class ConnectionPool
  DEFAULTS = {size: 5, timeout: 5}

  class LoggedOut < StandardError; end

  def self.wrap(options, &block)
    Wrapper.new(options, &block)
  end

  def initialize(options = {}, &block)
    raise ArgumentError, "Connection pool requires a block" unless block

    options = DEFAULTS.merge(options)

    @size = Integer(options.fetch(:size))
    @timeout = options.fetch(:timeout)

    @available = TimedStack.new(@size, &block)
    @key = :"pool-#{@available.object_id}"
    @key_count = :"pool-#{@available.object_id}-count"
  end

  def with(options = {})
    Thread.handle_interrupt(Exception => :never) do
      conn = checkout(options)
      logged_out = false
      begin
        Thread.handle_interrupt(Exception => :immediate) do
          yield conn
        rescue LoggedOut
          logged_out = true
          raise
        end
      ensure
        checkin(logged_out)
      end
    end
  end
  alias then with

  def checkout(options = {})
    if ::Thread.current[@key]
      ::Thread.current[@key_count] += 1
      ::Thread.current[@key]
    else
      ::Thread.current[@key_count] = 1
      ::Thread.current[@key] = @available.pop(options[:timeout] || @timeout)
    end
  end

  def checkin(logged_out)
    if ::Thread.current[@key]
      if ::Thread.current[@key_count] == 1
        @available.push(::Thread.current[@key]) unless logged_out
        ::Thread.current[@key] = nil
        ::Thread.current[@key_count] = nil
      else
        ::Thread.current[@key_count] -= 1
      end
    else
      raise ConnectionPool::Error, "no connections are checked out"
    end

    nil
  end

  ##
  # Shuts down the ConnectionPool by passing each connection to +block+ and
  # then removing it from the pool. Attempting to checkout a connection after
  # shutdown will raise +ConnectionPool::PoolShuttingDownError+.

  def shutdown(&block)
    @available.shutdown(&block)
  end

  ##
  # Reloads the ConnectionPool by passing each connection to +block+ and then
  # removing it the pool. Subsequent checkouts will create new connections as
  # needed.

  def reload(&block)
    @available.shutdown(reload: true, &block)
  end

  # Size of this connection pool
  attr_reader :size

  # Number of pool entries available for checkout at this instant.
  def available
    @available.length
  end
end

require_relative "connection_pool/timed_stack"
require_relative "connection_pool/wrapper"
