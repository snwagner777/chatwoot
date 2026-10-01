# Run through rails runner in the final production image with disposable services.
raise 'Expected production Rails boot' unless Rails.env.production?
raise 'Expected Community image' if Rails.root.join('enterprise').exist?

require 'rack/proxy'

middleware = Rails.application.middleware.map(&:klass)
proxies = middleware.select { |entry| entry <= Rack::Proxy }
raise "Production Rack proxy middleware: #{proxies.map(&:name).join(', ')}" if proxies.any?
raise 'Vite development proxy enabled in production' if ViteRuby.run_proxy?

response = Rack::MockRequest.new(Rails.application).get('/api', 'HTTP_HOST' => 'localhost')
raise "Production API health failed: #{response.status}" unless response.status == 200

puts({ rails_env: Rails.env, vite_mode: ViteRuby.config.mode, rack_proxy_middleware: proxies.map(&:name), api_status: response.status }.to_json)
