# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'time'

APP_ID = ENV.fetch('TPC_APP_ID', '816025')
PAGES = (ARGV.first || '20').to_i

# The rate that would exactly consume the 2,000,000 request monthly free tier over a 30 day month
FREE_TIER_REQUEST_RATE = 2_000_000 / 2_592_000.0
WARN_BURN_PERCENT = 15
FAIL_BURN_PERCENT = 30
# Rate is measured over at most this window, so the number always means "burn over the last 6 hours"
# rather than "burn over however long the last 2000 deliveries happened to span"
MAX_WINDOW_SECONDS = 6 * 60 * 60

def private_key
  inline = ENV.fetch('TPC_PRIVATE_KEY', nil)
  return OpenSSL::PKey::RSA.new(inline.gsub('\n', "\n")) unless inline.to_s.empty?

  path = ENV.fetch('TPC_KEY_PATH', nil)
  abort 'Set TPC_PRIVATE_KEY (PEM contents) or TPC_KEY_PATH.' if path.to_s.empty?

  OpenSSL::PKey::RSA.new(File.read(path))
end

PRIVATE_KEY = private_key

def base64url(data)
  Base64.urlsafe_encode64(data).delete('=')
end

def jwt_token
  now = Time.now.to_i
  header = base64url({ alg: 'RS256', typ: 'JWT' }.to_json)
  claims = base64url({ iat: now - 60, exp: now + (7 * 60), iss: APP_ID }.to_json)
  signing_input = "#{header}.#{claims}"
  "#{signing_input}.#{base64url(PRIVATE_KEY.sign(OpenSSL::Digest.new('SHA256'), signing_input))}"
end

def fetch_deliveries(http, pages)
  deliveries = []
  cursor = nil

  pages.times do
    path = '/app/hook/deliveries?per_page=100'
    path += "&cursor=#{cursor}" if cursor
    request = Net::HTTP::Get.new(path)
    request['Authorization'] = "Bearer #{jwt_token}"
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'
    request['User-Agent'] = 'todo-pr-checker-delivery-audit'
    response = http.request(request)
    abort "HTTP #{response.code} listing deliveries." unless response.code == '200'

    batch = JSON.parse(response.body)
    break if batch.empty?

    deliveries.concat(batch)
    cursor = response['Link'].to_s[/cursor=([^>&]+)>;\s*rel="next"/, 1]
    break unless cursor
  end

  deliveries
end

http = Net::HTTP.new('api.github.com', 443)
http.use_ssl = true
http.open_timeout = 20
http.read_timeout = 60

deliveries = fetch_deliveries(http, PAGES)
abort 'No deliveries returned.' if deliveries.empty?

stamps = deliveries.filter_map { |delivery| Time.parse(delivery['delivered_at']) rescue nil }.sort
now = Time.now.utc
cutoff = now - MAX_WINDOW_SECONDS
# Clip to the cutoff when the sample reaches further back, and measure to now so idle time counts
window_start = [stamps.first, cutoff].max
span = now - window_start
abort 'Sample covers no measurable time span.' unless span.positive?

deliveries = deliveries.select { |delivery| (Time.parse(delivery['delivered_at']) rescue now) > window_start }
abort 'No deliveries inside the measurement window.' if deliveries.empty?

rate = deliveries.size / span
burn = rate / FREE_TIER_REQUEST_RATE * 100
ignored_share = 100.0 * deliveries.count { |delivery| delivery['status_code'].to_i == 204 } / deliveries.size

# Group counts only; the identifiers themselves are never printed
counts = deliveries.group_by { |delivery| delivery['installation_id'] }.transform_values(&:size)
busiest_share = 100.0 * counts.values.max / deliveries.size

truncated = stamps.first < cutoff ? ' (clipped to 6h)' : ''
puts "Sampled #{deliveries.size} deliveries over #{(span / 60).round(1)} min#{truncated}"
puts "Rate: #{rate.round(2)}/s (#{(rate * 86_400).round} per day)"
puts "Free tier burn: #{burn.round}% of the monthly request allowance"
puts "Ignored (204): #{ignored_share.round(1)}%"
puts "Distinct installations in sample: #{counts.size}"
puts "Busiest single installation: #{busiest_share.round(1)}% of deliveries"
puts

puts '== Events =='
deliveries.group_by { |delivery| "#{delivery['event']}.#{delivery['action'] || '-'}" }
          .sort_by { |_, rows| -rows.size }
          .first(8)
          .each do |event, rows|
  puts "  #{event.ljust(34)}#{rows.size.to_s.rjust(6)}  #{(100.0 * rows.size / deliveries.size).round(1)}%"
end
puts

if burn >= FAIL_BURN_PERCENT
  puts "FAIL: burning #{burn.round}% of the monthly request allowance."
  puts 'To identify the responsible installation(s), run the local hook_deliveries.rb script.'
  exit 1
end

puts burn >= WARN_BURN_PERCENT ? "WARN: burning #{burn.round}% of the monthly request allowance." : "OK: burning #{burn.round}% of the monthly request allowance."
