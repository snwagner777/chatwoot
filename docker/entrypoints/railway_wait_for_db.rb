require 'uri'

begin
  database_url = ENV.fetch('DATABASE_URL', '')
  uri = URI.parse(database_url) unless database_url.empty?
  abort 'Invalid PostgreSQL connection settings' unless uri.nil? || %w[postgres postgresql].include?(uri.scheme)

  host = uri&.host || ENV['PGHOST'] || ENV['POSTGRES_HOST'] || 'localhost'
  port = Integer(uri&.port || ENV['PGPORT'] || ENV['POSTGRES_PORT'] || '5432')
  timeout = Integer(ENV.fetch('DATABASE_WAIT_TIMEOUT', '60'))
  abort 'Invalid PostgreSQL readiness settings' unless port.between?(1, 65_535) && timeout.positive?
rescue URI::InvalidURIError, ArgumentError
  abort 'Invalid PostgreSQL connection settings'
end

puts 'Waiting for database readiness...'
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
until system('pg_isready', '--quiet', '--host', host, '--port', port.to_s)
  abort 'Database readiness timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 0.25
end
puts 'Database is ready.'
