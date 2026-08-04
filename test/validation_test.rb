# frozen_string_literal: true

require_relative 'test_helper'

class DefaultValidationFixtureTest < Minitest::Test
  EXPECTED_ALERT_LINES = {
    'validation.css' => [1, 2],
    'validation.html' => [1, 11],
    'validation.js' => [1, 3, 5, 7, 9, 20],
    'validation.php' => [2, 6, 10]
  }.freeze

  def setup
    @scanner = Sinatra::Application.new!
    config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @default_options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')
  end

  EXPECTED_ALERT_LINES.each do |file_name, expected_lines|
    define_method("test_default_options_find_expected_alerts_in_#{file_name.tr('.', '_')}") do
      fixture_path = File.expand_path("../validation/#{file_name}", __dir__)
      fixture_lines = File.readlines(fixture_path, chomp: true)
      expected_count = fixture_lines.filter_map { |line| line[/Alerts with default options: (\d+)/, 1] }.first
      file_changes = fixture_lines.each_with_index.map do |text, index|
        { line: index + 1, text: text }
      end

      todo_changes, unsupported_files = @scanner.send(:check_for_todos, { file_name => file_changes }, @default_options)
      actual_lines = todo_changes.fetch(file_name, []).map { |change| change[:line] }

      refute_nil expected_count
      assert_equal expected_lines.length, expected_count.to_i
      assert_equal expected_lines, actual_lines
      assert_empty unsupported_files
    end
  end
end

class ActionItemMatchingPermutationTest < Minitest::Test
  OPTION_KEYS = %w[check_inline_comments standalone_items multiline_comments case_sensitive].freeze
  EXPECTED_ALERT_LINES = {
    [false, false, false, false] => [2, 3, 4, 5, 10, 11, 23, 25, 28, 29, 30, 32],
    [false, false, false, true] => [2, 3, 4, 10, 11, 23, 25, 28, 29, 30],
    [false, false, true, false] => [2, 3, 4, 5, 10, 11, 15, 16, 23, 25, 28, 29, 30, 32],
    [false, false, true, true] => [2, 3, 4, 10, 11, 15, 16, 23, 25, 28, 29, 30],
    [false, true, false, false] => [2, 5, 10, 25, 30, 32],
    [false, true, false, true] => [2, 10, 25, 30],
    [false, true, true, false] => [2, 5, 10, 15, 25, 30, 32],
    [false, true, true, true] => [2, 10, 15, 25, 30],
    [true, false, false, false] => [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 23, 25, 26, 28, 29, 30, 32],
    [true, false, false, true] => [2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 23, 25, 26, 28, 29, 30],
    [true, false, true, false] => [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 15, 16, 19, 20, 23, 25, 26, 28, 29, 30, 32],
    [true, false, true, true] => [2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 15, 16, 19, 20, 23, 25, 26, 28, 29, 30],
    [true, true, false, false] => [2, 5, 7, 9, 10, 12, 25, 26, 30, 32],
    [true, true, false, true] => [2, 7, 9, 10, 12, 25, 26, 30],
    [true, true, true, false] => [2, 5, 7, 9, 10, 12, 15, 19, 25, 26, 30, 32],
    [true, true, true, true] => [2, 7, 9, 10, 12, 15, 19, 25, 26, 30]
  }.freeze

  def setup
    @scanner = Sinatra::Application.new!
    fixture_path = File.expand_path('../validation/validation-options.js', __dir__)
    @changes = {
      'validation-options.js' => File.readlines(fixture_path, chomp: true).each_with_index.map do |text, index|
        { line: index + 1, text: text }
      end
    }
  end

  EXPECTED_ALERT_LINES.each do |values, expected_lines|
    option_name = OPTION_KEYS.zip(values).map { |key, value| "#{key}=#{value}" }.join(',')
    define_method("test_#{option_name.tr('=,', '__')}") do
      options = OPTION_KEYS.zip(values).to_h.merge('action_items' => ['TODO'], 'add_languages' => [])

      todo_changes, unsupported_files = @scanner.send(:check_for_todos, @changes, options)
      actual_lines = todo_changes.fetch('validation-options.js', []).map { |change| change[:line] }

      assert_equal expected_lines, actual_lines
      assert_empty unsupported_files
    end
  end
end
