# frozen_string_literal: true

require 'openssl'

ENV['RACK_ENV'] = 'test'
ENV['GITHUB_APP_IDENTIFIER'] = '816025'
ENV['GITHUB_PRIVATE_KEY'] = OpenSSL::PKey::RSA.generate(2048).to_pem
ENV['GITHUB_WEBHOOK_SECRET'] = 'test-webhook-secret'

require 'json'
require 'minitest/autorun'
require 'rack/test'
require_relative '../app'

Sinatra::Application.set :test_calls, []
ORIGINAL_INITIATE_CHECK_RUN = Sinatra::Application.instance_method(:initiate_check_run)

Sinatra::Application.helpers do
  def authenticate_app
    settings.test_calls << [:authenticate_app]
  end

  def authenticate_installation(payload)
    settings.test_calls << [:authenticate_installation, payload.dig('installation', 'id')]
  end

  def create_check_run(full_repo_name, head_sha)
    settings.test_calls << [:create_check_run, full_repo_name, head_sha]
    Struct.new(:id).new(123)
  end

  def initiate_check_run(**arguments)
    settings.test_calls << [:initiate_check_run, arguments]
  end
end
