require "msgpack"
require "http"
require "statsd"

class Fiber
  property current_datadog_span : Datadog::Span?
  property current_datadog_trace : Datadog::Trace?
end

class HTTP::Client
  def exec_without_instrumentation(request : HTTP::Request)
    exec_internal request
  end
end

module Datadog
  alias Trace = Array(Span)
  alias TraceSet = Array(Trace)

  CONFIG = Configuration.new
  DEFAULT_TRACER = DefaultTracer.new
  VERSION = "0.1.0"

  # Yields the `Datadog::Configuration` in use
  def self.configure
    yield CONFIG
  end

  # Return the currently configured tracer
  def self.tracer
    CONFIG.tracer
  end

  @@metrics : Statsd::Client?

  # Return a metrics client to allow you to report metrics via Statsd.
  def self.metrics
    @@metrics ||= Statsd::Client.new(CONFIG.agent_host, CONFIG.metrics_agent_port)
  end

  # Datadog can be configured by passing a block to `Datadog.configure`.
  #
  # ```
  # Datadog.configure do |c|
  #   # Define your service
  #   c.service "my-web-app", type: "http"
  #
  #   # Set global tags
  #   c.tags = {
  #     "environment" => ENV["APP_ENV"],
  #     "k8s_pod" => ENV["HOSTNAME"],
  #     "k8s_deployment" => ENV["HOSTNAME"][/\A\w+-\w+/],
  #   }
  # end
  # ```
  class Configuration
    property? tracing_enabled : Bool = ENV["DD_TRACING_ENABLED"]? == "true"

    # The agent host is the physical or logical IP address where your Datadog agent is running, defaults to `localhost`
    getter agent_host : String = resolve_ip(ENV.fetch("DD_AGENT_HOST", "localhost"))
    def agent_host=(host)
      @agent_host = self.class.resolve_ip(host)
    end

    # The trace-agent port is the TCP port that the APM server is listening on, defaults to 8126.
    property trace_agent_port : Int32 = ENV.fetch("DD_TRACE_AGENT_PORT", "8126").to_i

    # The metrics-agent port is the UDP port that the metrics agent is listening on, defaults to 8125.
    property metrics_agent_port : Int32 = ENV.fetch("DD_METRICS_AGENT_PORT", "8125").to_i

    # Returns a `Datadog::Span::Metadata` containing any tags you want to set globally on your spans and metrics.
    getter tags = Span::Metadata.new

    # Set tags you want to set globally on your spans and metrics.
    def tags=(tags : Hash)
      @tags = tags.transform_values(&.as(MessagePack::Type))
    end

    # Declare a service name with a given type, the first will become the default service when reporting spans.
    def service(name : String, type = "http")
      service = Service.new(name: name, type: type)
      @service ||= name
      @services[name] = service
    end

    # :nodoc:
    def apm_base_url
      URI.parse("http://#{CONFIG.agent_host}:#{CONFIG.trace_agent_port}")
    end

    # Return the current tracer adapter, defaults to the Datadog MessagePack/HTTP tracer.
    # This interface is still being defined to allow for adapters like OpenTracing.
    setter tracer : Tracer?
    def tracer
      @tracer || DEFAULT_TRACER
    end

    # Get or set the default service name to use when no other services are specified.
    property service : String?

    # :nodoc:
    def default_service
      @services[@service]
    end

    @services = Hash(String?, Service).new(
      default_value: Service.new(
        name: "unknown-service",
        type: "http",
      ),
    )

    # :nodoc:
    def self.resolve_ip(host)
      # It doesn't seem to work well with IPv6, so let's stick with IPv4 addresses
      Socket::Addrinfo
        .udp(host, "")
        .map(&.ip_address.address)
        .reject { |addr| addr.includes? ':' }
        .first
    end
  end

  # :nodoc:
  class Service
    getter name : String
    getter type : String

    def initialize(@name, @type)
    end
  end

  # All tracer implementations must implement this interface
  module Tracer
    # Yields a new span to the given block, setting all of the values you pass to it
    abstract def trace(name : String, resource : String, current_span, parent_id, trace_id, span_id, service, service_name, start, type, tags, & : Span ->)
  end

  class DefaultTracer
    include Tracer

    @current_traces = Array(Array(Span)).new
    @lock = Mutex.new # Don't want to lose spans while we report them

    def active_trace
      if trace = Fiber.current.current_datadog_trace
        trace
      else
        trace = Fiber.current.current_datadog_trace = Trace.new
        @lock.synchronize { @current_traces << trace }
        trace
      end
    end

    def active_span
      Fiber.current.current_datadog_span
    end

    def trace(
      name : String,
      resource : String,
      current_span = active_span,
      parent_id = current_span.try(&.id) || 0i64,
      trace_id = current_span.try(&.trace_id) || Random::Secure.rand(Int64).abs,
      span_id = Random::Secure.rand(Int64).abs,
      service = CONFIG.default_service,
      service_name = service.name,
      start = Time.utc,
      type = service.type,
      tags = Span::Metadata.new,
    )
      if current_span = active_span
        current_trace_id = current_span.trace_id
      end

      span = Span.new(
        trace_id: current_trace_id || Random::Secure.rand(Int64).abs,
        id: span_id,
        parent_id: parent_id,
        name: name,
        service: service_name,
        resource: resource,
        type: type,
        start: (start.to_unix_f * 1_000_000_000).to_i64,
        duration: 0,
        tags: CONFIG.tags.merge(tags),
        metrics: Span::Metadata.new,
        allocations: 0i64,
        error: 0,
      )
      if parent_id == 0
        span.metrics["system.pid"] = Process.pid
      end

      # If tracing is disabled, we yield a span that we then just throw away
      unless CONFIG.tracing_enabled?
        return yield span
      end

      active_trace << span
      previous_span = active_span
      Fiber.current.current_datadog_span = span
      start_monotonic = Time.monotonic
      
      begin
        yield span
      rescue ex
        span.error += 1
        raise ex
      ensure
        span.duration = (Time.monotonic - start_monotonic).total_nanoseconds.to_i32
        Fiber.current.current_datadog_span = previous_span
        if previous_span.nil?
          Fiber.current.current_datadog_trace = nil
        end
      end
    end

    # :nodoc:
    def report
      @lock.synchronize do
        return if @current_traces.empty?

        HTTP::Client.new(CONFIG.apm_base_url).exec_without_instrumentation(
          HTTP::Request.new(
            method: "POST",
            resource: "/v0.4/traces",
            headers: HTTP::Headers {
              "Content-Type" => "application/msgpack",
              "Datadog-Meta-Lang" => "crystal",
              "Datadog-Meta-Lang-Version" => Crystal::VERSION,
              "Datadog-Meta-Tracer-Version" => VERSION,
              "Host" => "#{CONFIG.agent_host}:#{CONFIG.trace_agent_port}",
              "User-Agent" => "Crystal Datadog shard (https://github.com/jgaskins/datadog)",
              "X-Datadog-Trace-Count" => @current_traces.size.to_s,
            },
            body: @current_traces.to_msgpack,
          )
        )
        @current_traces.clear
      end
    end

    def handle_error(ex)
      # ...
    end
  end

  # A span is a unit of measurable work for Datadog.
  class Span
    include MessagePack::Serializable

    alias Metadata = Hash(String, MessagePack::Type)

    getter trace_id : Int64
    @[MessagePack::Field(key: "span_id")]
    getter id : Int64
    getter parent_id : Int64
    getter name : String
    getter service : String
    getter resource : String
    getter type : String
    getter start : Int64
    property duration : Int32
    @[MessagePack::Field(key: "meta")]
    getter tags : Metadata
    getter metrics : Metadata
    getter allocations : Int64
    property error : Int32

    def initialize(@trace_id, @id, @parent_id, @name, @service, @resource, @type, @start, @duration, @tags, @metrics, @allocations, @error)
    end
  end
end

spawn do
  loop do
    sleep 1
    spawn Datadog.tracer.report
  rescue ex
    # Make some sort of affordance to report to an error-tracking service
    Datadog.tracer.handle_error ex
  end
end

at_exit { Datadog.tracer.report }
