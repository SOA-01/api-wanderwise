# frozen_string_literal: true

require_relative '../require_app'
require_app

require 'shoryuken'
require 'logger'
require 'redis'
require_relative 'job_reporter'

module FindFlights
  # Worker to find flights
  class Worker
    Figaro.application = Figaro::Application.new(
      environment: ENV['RACK_ENV'] || 'development',
      path: File.expand_path('config/secrets.yml')
    )
    Figaro.load
    def self.config = Figaro.env

    Shoryuken.sqs_client = Aws::SQS::Client.new(
      access_key_id: config.AWS_ACCESS_KEY_ID,
      secret_access_key: config.AWS_SECRET_ACCESS_KEY,
      region: config.AWS_REGION
    )

    include Shoryuken::Worker
    Shoryuken.sqs_client_receive_message_opts = { wait_time_seconds: 20 }
    shoryuken_options queue: Figaro.env.WANDERWISE_QUEUE_URL, auto_delete: true

    def perform(_sqs_msg, request) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      logger.info "Processing request: #{request}"
      request = JSON.parse(request) if request.is_a?(String)

      logger.info "Initializing JobReporter with request: #{request.to_json}"
      reporter = WanderWise::JobReporter.new(request.to_json, Worker.config)
      logger.info 'JobReporter initialized successfully'

      reporter.report("Started processing request #{request['id']}")

      cache_key = generate_cache_key(request)

      reporter.report("Checking for cached results for request #{request['id']}")
      if redis.get(cache_key)
        reporter.report("Results already cached for request #{request['id']}")
        logger.info "Results already cached for request: #{request}"
        return
      end

      reporter.report("Fetching flight data for request #{request['id']}")

      amadeus_api = WanderWise::AmadeusAPI.new
      flight_mapper = WanderWise::FlightMapper.new(amadeus_api)

      flights = flight_mapper.find_flight(request)

      simulate_progress(reporter) do
        flights = flight_mapper.find_flight(request)
        if flights.any?
          serialized_data = flights.map(&:to_h).to_json
          redis.set(cache_key, serialized_data, ex: cache_expiry_time)
          reporter.report("Results successfully cached for request #{request['id']}")
        else
          reporter.report("No flights found for request #{request['id']}")
          logger.error "No flights found for request: #{request}"
        end
      end
    rescue StandardError => e
      reporter&.report("Processing request #{request['id']}: Error - #{e.message}")
      logger.error "Error processing request: #{request} - #{e.message}"
      raise e
    end

    private

    # Redis client
    def redis
      @redis ||= Redis.new(url: Figaro.env.REDIS_URL) # Ensure REDIS_URL is set in your environment
    end

    # Generate a unique cache key based on the request parameters
    def generate_cache_key(request)
      "flights:#{request['originLocationCode']}:#{request['destinationLocationCode']}:#{request['departureDate']}:#{request['adults']}"
    end

    # Cache expiry time in seconds (e.g., 1 hour)
    def cache_expiry_time
      120
    end

    def logger
      @logger ||= Logger.new($stdout)
    end

    def simulate_progress(reporter)
      (1..5).each do |progress_step|
        sleep(1)

        reporter.report("Processing step #{progress_step} for request #{reporter.request_id}")
      end
      yield if block_given?
    end
  end
end
