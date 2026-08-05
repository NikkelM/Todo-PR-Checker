# frozen_string_literal: true

require_relative 'test_helper'

class IssueConfigurationTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker: {}\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  def test_create_issues_defaults_to_never
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal 'never', options['create_issues']
    assert_empty options['issue_labels']
  end

  def test_create_issues_accepts_supported_values
    %w[never links always].each do |value|
      @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: #{value}\n")

      options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

      assert_equal value, options['create_issues']
    end
  end

  def test_invalid_create_issues_uses_default
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: sometimes\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal 'never', options['create_issues']
  end

  def test_create_issues_from_forks_defaults_to_false
    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal false, options['create_issues_from_forks']
  end

  def test_create_issues_from_forks_accepts_true
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues_from_forks: true\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal true, options['create_issues_from_forks']
  end

  def test_issue_labels_accepts_a_list_of_labels
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  issue_labels: ['todo', 'technical debt']\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_equal ['todo', 'technical debt'], options['issue_labels']
  end

  def test_invalid_issue_labels_use_default
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  issue_labels: 'todo'\n")

    options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')

    assert_empty options['issue_labels']
  end
end

class IssueContentTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @change = { line: 5, text: '// TODO: Fix this', item: 'TODO' }
  end

  def test_title_names_the_action_item_file_and_line
    title = @scanner.send(:create_issue_title, 'src/app.js', @change)

    assert_equal '[TODO] app.js:5 - Fix this', title
  end

  def test_title_omits_the_excerpt_when_the_action_item_stands_alone
    title = @scanner.send(:create_issue_title, 'src/app.js', { line: 5, text: '// TODO', item: 'TODO' })

    assert_equal '[TODO] app.js:5', title
  end

  def test_title_excerpt_is_truncated_and_strips_comment_delimiters
    long_change = { line: 5, text: '  /* FIXME: this recalculates the whole page on every keystroke, debounce it */', item: 'FIXME' }

    title = @scanner.send(:create_issue_title, 'src/components/DataGridPagination.tsx', long_change)

    assert title.start_with?('[FIXME] DataGridPagination.tsx:5 - this recalculates')
    assert title.end_with?('…')
    refute_includes title, '*/'
    assert_operator title.length, :<=, 90
  end

  def test_body_embeds_a_snippet_covering_the_configured_additional_lines
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1)

    assert_includes body, 'https://github.com/octocat/example/blob/head-sha/src/app.js#L5-L6'
    assert_includes body, 'https://github.com/octocat/example/pull/7'
    assert_includes body, '`TODO`'
  end

  def test_body_links_the_pull_request_title_when_it_is_known
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1, 'Add the new parser')

    assert_includes body, 'Identified by [Todo PR Checker](https://github.com/marketplace/todo-pr-checker) in [PR #7: Add the new parser](https://github.com/octocat/example/pull/7)'
  end

  def test_body_falls_back_to_a_plain_link_without_a_pull_request_title
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1, '  ')

    assert_includes body, 'Identified by [Todo PR Checker](https://github.com/marketplace/todo-pr-checker) in https://github.com/octocat/example/pull/7'
  end

  def test_body_ends_with_a_separated_sponsor_line
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1)

    assert_includes body, "\n----\nDid I do good? Let me know by [helping maintain this app](https://github.com/sponsors/NikkelM)!"
    assert_operator body.index('Did I do good?'), :<, body.index('<!-- todo-pr-checker |')
    assert body.rstrip.end_with?('-->')
  end

  def test_body_links_a_single_line_when_no_additional_lines_are_configured
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 0)

    assert_includes body, 'https://github.com/octocat/example/blob/head-sha/src/app.js#L5'
    refute_includes body, '#L5-L'
  end

  def test_body_does_not_link_past_the_end_of_the_file
    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1, nil, last_diff_line: 5)

    assert_includes body, 'https://github.com/octocat/example/blob/head-sha/src/app.js#L5'
    refute_includes body, '#L5-L6'
  end

  def test_issue_link_encodes_the_title_and_body
    link = @scanner.send(:create_issue_link, 'octocat/example', 'A title', 'A body', [])

    assert link.start_with?('https://github.com/octocat/example/issues/new?')
    assert_includes link, 'title=A+title'
    assert_includes link, 'body=A+body'
    refute_includes link, 'labels='
  end

  def test_issue_link_includes_configured_labels
    link = @scanner.send(:create_issue_link, 'octocat/example', 'A title', 'A body', ['todo', 'technical debt'])

    assert_includes link, 'labels=todo%2Ctechnical+debt'
  end
end

class IssueContentInjectionTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @change = { line: 5, text: '// TODO: Fix this', item: 'TODO', description: ' Fix this' }
  end

  def test_pull_request_title_cannot_break_out_of_the_link
    hostile_title = 'Fix the thing](https://evil.example) [x'

    body = @scanner.send(:create_issue_body, 'src/app.js', @change, 'octocat/example', 'head-sha', 7, 1, hostile_title)

    # The closing bracket is escaped, so the label continues and the attacker's destination stays literal text
    assert_includes body, '[PR #7: Fix the thing\\](https://evil.example) \\[x](https://github.com/octocat/example/pull/7)'
    refute_match(/\[PR #7[^\]]*[^\\]\]\(https:\/\/evil/, body)
  end

  def test_file_path_cannot_break_out_of_the_link_destination
    hostile_file = 'a) [Click here](https://evil.example) (b.rb'

    body = @scanner.send(:create_issue_body, hostile_file, @change, 'octocat/example', 'head-sha', 7, 1)

    # Every character that could end the destination is percent encoded, so the link stays on github.com
    # The raw path only appears inside a code span, which binds tighter than a link and renders it inert
    assert_includes body, '](https://github.com/octocat/example/blob/head-sha/a%29%20%5BClick%20here%5D%28https%3A'
    assert_includes body, "[`#{hostile_file}`](https://github.com/octocat/example/blob/head-sha/a%29"
  end

  def test_file_path_with_backticks_cannot_break_out_of_the_code_span
    body = @scanner.send(:create_issue_body, 'we`ird.rb', @change, 'octocat/example', 'head-sha', 7, 1)

    assert_includes body, '``we`ird.rb``'
  end

  def test_marker_cannot_be_terminated_early_through_the_file_path_or_item
    change = { line: 5, text: '// X fix', item: 'X-->' }

    fingerprint = @scanner.send(:create_issue_fingerprint, 'src/a-->b.rb', change)

    refute_includes fingerprint, '-->'
    assert_includes fingerprint, 'file: src/ab.rb'
    assert_includes fingerprint, 'item: X'
  end
end

class IssueCreationTest < Minitest::Test
  def setup
    @calls = []
    @files = []
    @issues = []
    @searches = []
    calls = @calls
    files = @files
    issues = @issues
    searches = @searches
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker:\n  create_issues: always\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    installation_client.define_singleton_method(:pull_request_files) do |*, page:, **|
      page == 1 ? files : []
    end
    installation_client.define_singleton_method(:issue_comments) { |*, **| [] }
    installation_client.define_singleton_method(:pull_request) do |*, **|
      repo = Struct.new(:full_name).new('octocat/example')
      Struct.new(:title, :created_at, :base, :head).new(
        'Add the new parser', Time.utc(2026, 8, 5, 12, 0, 0),
        Struct.new(:ref).new('main'), Struct.new(:repo).new(repo)
      )
    end
    installation_client.define_singleton_method(:search_issues) do |query, page:, **|
      searches << query
      Struct.new(:items).new(page == 1 ? issues : [])
    end
    installation_client.define_singleton_method(:update_check_run) do |*args, **kwargs|
      calls << { name: :update_check_run, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:add_comment) do |*args, **kwargs|
      calls << { name: :add_comment, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:create_issue) do |*args, **kwargs|
      calls << { name: :create_issue, args: args, kwargs: kwargs }
      number = calls.length
      Struct.new(:number, :html_url).new(number, "https://github.com/octocat/example/issues/#{number}")
    end
    installation_client.define_singleton_method(:post) do |path, payload|
      request = JSON.parse(payload)
      calls << { name: :graphql, args: [path], kwargs: request }

      if request['query'].start_with?('query')
        labels = [Struct.new(:id, :name).new('label-todo', 'todo'), Struct.new(:id, :name).new('label-debt', 'technical debt')]
        repository = Struct.new(:id, :labels).new('repo-id', Struct.new(:nodes).new(labels))
        next Struct.new(:data, :errors).new(Struct.new(:repository).new(repository), nil)
      end

      variables = request['variables']
      created_count = variables.keys.count { |key| key.start_with?('title') }
      issue_fields = {}
      created_count.times do |index|
        calls << { name: :create_issue, args: [nil, variables["title#{index}"], variables["body#{index}"]], kwargs: { labels: variables['labels'] } }
        number = calls.length
        issue_fields["issue#{index}"] = Struct.new(:issue).new(Struct.new(:number, :url).new(number, "https://github.com/octocat/example/issues/#{number}"))
      end
      data = Struct.new(*issue_fields.keys.map(&:to_sym)).new(*issue_fields.values)
      Struct.new(:data, :errors).new(data, nil)
    end

    @scanner = Sinatra::Application.new!
    @scanner.instance_variable_set(:@installation_client, installation_client)
  end

  def test_always_creates_one_issue_per_action_item
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,3 @@\n+// TODO: First\n+const value = true;\n+// FIXME: Second\n")

    run_check

    created = @calls.select { |call| call[:name] == :create_issue }

    assert_equal 2, created.length
    assert_equal '[todo] app.js:1 - First', created.first[:args][1]
    assert_equal '[fixme] app.js:3 - Second', created.last[:args][1]
  end

  def test_never_does_not_create_issues_or_offer_the_action
    @config_file.content = Base64.strict_encode64("todo-pr-checker: {}\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }
    comment = @calls.find { |call| call[:name] == :add_comment }

    refute @calls.any? { |call| call[:name] == :create_issue }
    refute final_check[:kwargs].key?(:actions)
    refute_includes comment[:args][2], 'issues/new'
  end

  def test_links_mode_adds_issue_links_and_a_check_run_action
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: links\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }
    comment = @calls.find { |call| call[:name] == :add_comment }

    refute @calls.any? { |call| call[:name] == :create_issue }
    assert_includes comment[:args][2], 'https://github.com/octocat/example/issues/new?'
    assert_includes comment[:args][2], 'Create an issue for [`todo` on line 1]'
    assert_equal [{ label: 'Create all issues', description: 'Create an issue for each identified action item', identifier: 'create_issues' }], final_check[:kwargs][:actions]
  end

  def test_a_snippet_with_several_untracked_items_uses_the_plural_creation_line
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: links\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,2 @@\n+// TODO: First\n+// FIXME: Second\n")

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], 'Create issues for [`todo` on line 1]'
    assert_includes comment[:args][2], '· [`fixme` on line 2]'
    refute_includes comment[:args][2], 'Create an issue for'
  end

  def test_creation_links_are_only_offered_for_untracked_items
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: links\n")
    @issues << existing_issue(11, 'Tracking issue', fingerprint_for('app.js', 'todo', '// TODO: First'))
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,2 @@\n+// TODO: First\n+// FIXME: Second\n")

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], 'Action items tracked in issues: [#11: `todo` on line 1]'
    assert_includes comment[:args][2], 'Create an issue for [`fixme` on line 2]'
  end

  def test_requested_action_creates_issues_and_removes_the_action
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: links\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check(create_issues_now: true)

    final_check = @calls.reverse.find { |call| call[:name] == :update_check_run }

    assert_equal 1, @calls.count { |call| call[:name] == :create_issue }
    refute final_check[:kwargs].key?(:actions)
    assert_match(/Action items tracked in issues: \[#\d+: `todo` on line 1\]/, final_check[:kwargs].dig(:output, :summary))
  end

  def test_existing_issues_are_not_created_again
    @issues << existing_issue(11, 'Anything the user renamed it to', fingerprint_for('app.js', 'todo', '// TODO: First'))
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,3 @@\n+// TODO: First\n+const value = true;\n+// FIXME: Second\n")

    run_check

    created = @calls.select { |call| call[:name] == :create_issue }

    assert_equal 1, created.length
    assert_includes created.first[:args][1], '[fixme]'
  end

  def test_shifted_line_numbers_do_not_create_a_second_issue
    @issues << existing_issue(11, '[todo] app.js:1 - First', fingerprint_for('app.js', 'todo', '// TODO: First'))
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,3 @@\n+const value = true;\n+const other = false;\n+// TODO: First\n")

    run_check

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  def test_comment_links_existing_issues_instead_of_offering_to_create_them
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: links\n")
    @issues << existing_issue(11, 'Tracking issue', fingerprint_for('app.js', 'todo', '// TODO: First'))
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: First\n")

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_includes comment[:args][2], 'Action items tracked in issues: [#11: `todo` on line 1](https://github.com/octocat/example/issues/11)'
    refute_includes comment[:args][2], 'issues/new?'
  end

  def test_comment_links_newly_created_issues_without_further_requests
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    comment = @calls.find { |call| call[:name] == :add_comment }

    assert_match(%r{Action items tracked in issues: \[#\d+: `todo` on line 1\]\(https://github\.com/octocat/example/issues/\d+\)}, comment[:args][2])
    refute_includes comment[:args][2], 'Created 1 issue'
    assert_equal 1, @searches.length
  end

  def test_created_issue_body_contains_the_deduplication_marker
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    created = @calls.find { |call| call[:name] == :create_issue }

    assert_includes created[:args][2], '<!-- todo-pr-checker | file: app.js | item: todo | text: // TODO: Fix this -->'
    assert_includes created[:args][2], 'Please do not remove or edit it.'
    assert_includes created[:args][2], 'Identified by [Todo PR Checker]'
    assert_includes created[:args][2], 'is not updated if the action item moves to a different line'
  end

  def test_existing_issues_are_looked_up_with_a_single_search_request
    @files.concat([
                    Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: First\n"),
                    Struct.new(:filename, :patch).new('other.js', "@@ -0,0 +1 @@\n+// FIXME: Second\n")
                  ])

    run_check

    assert_equal 1, @searches.length
    assert_includes @searches.first, 'repo:octocat/example'
    assert_includes @searches.first, 'in:body'
    assert_equal 2, @calls.count { |call| call[:name] == :create_issue }
  end

  def test_configured_labels_are_applied_to_created_issues
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: always\n  issue_labels: ['todo']\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,2 @@\n+// TODO: First\n+// FIXME: Second\n")

    run_check

    created = @calls.find { |call| call[:name] == :create_issue }

    assert_equal ['label-todo'], created[:kwargs][:labels]
  end

  def test_labels_that_do_not_exist_in_the_repository_are_ignored
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: always\n  issue_labels: ['todo', 'does not exist']\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1,2 @@\n+// TODO: First\n+// FIXME: Second\n")

    run_check

    created = @calls.find { |call| call[:name] == :create_issue }

    assert_equal ['label-todo'], created[:kwargs][:labels]
  end

  def test_a_single_issue_is_created_with_one_request
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    assert_equal 1, @calls.count { |call| call[:name] == :create_issue }
    refute @calls.any? { |call| call[:name] == :graphql }
  end

  def test_a_single_issue_with_labels_also_uses_one_request
    @config_file.content = Base64.strict_encode64("todo-pr-checker:\n  create_issues: always\n  issue_labels: ['todo']\n")
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")

    run_check

    created = @calls.find { |call| call[:name] == :create_issue }

    refute @calls.any? { |call| call[:name] == :graphql }
    assert_equal ['todo'], created[:kwargs][:labels]
  end

  def test_all_issues_are_created_with_a_single_batched_request
    patch = "@@ -0,0 +1,5 @@\n"
    patch += (1..5).map { |line| "+// TODO item #{line}\n" }.join
    @files << Struct.new(:filename, :patch).new('app.js', patch)

    run_check

    graphql_calls = @calls.select { |call| call[:name] == :graphql }
    mutations = graphql_calls.reject { |call| call[:kwargs]['query'].start_with?('query') }

    assert_equal 5, @calls.count { |call| call[:name] == :create_issue }
    assert_equal 1, mutations.length
    assert_equal 2, graphql_calls.length
  end

  def test_the_number_of_issues_created_in_one_run_is_capped
    patch = "@@ -0,0 +1,60 @@\n"
    patch += (1..60).map { |line| "+// TODO item #{line}\n" }.join
    @files << Struct.new(:filename, :patch).new('app.js', patch)

    run_check

    assert_equal 50, @calls.count { |call| call[:name] == :create_issue }
  end

  def test_issues_are_not_created_without_action_items
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+const value = true;\n")

    run_check

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  private

  def existing_issue(number, title, fingerprint)
    Struct.new(:number, :title, :body, :html_url).new(
      number, title, "<!-- todo-pr-checker | #{fingerprint} -->", "https://github.com/octocat/example/issues/#{number}"
    )
  end

  def fingerprint_for(file, item, text)
    @scanner.send(:create_issue_fingerprint, file, { item: item, text: text })
  end

  def run_check(create_issues_now: false)
    arguments = {
      full_repo_name: 'octocat/example',
      pull_number: 7,
      head_sha: 'head-sha',
      check_run_id: 123
    }
    arguments[:requested_action] = 'create_issues' if create_issues_now
    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, **arguments)
  end
end

class ForkConfigurationTest < Minitest::Test
  def setup
    @calls = []
    @files = []
    calls = @calls
    files = @files
    @head_config = "todo-pr-checker:\n  create_issues: always\n"
    @base_config = "todo-pr-checker: {}\n"
    configs = -> (ref) { ref == 'main' ? @base_config : @head_config }
    @configs = configs
    @head_repo = 'attacker/example'
    head_repo = -> { @head_repo }
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) do |*, ref:, **|
      Struct.new(:content).new(Base64.strict_encode64(configs.call(ref)))
    end
    installation_client.define_singleton_method(:pull_request_files) do |*, page:, **|
      page == 1 ? files : []
    end
    installation_client.define_singleton_method(:issue_comments) { |*, **| [] }
    installation_client.define_singleton_method(:pull_request) do |*, **|
      repo = Struct.new(:full_name).new(head_repo.call)
      Struct.new(:title, :created_at, :base, :head).new(
        'Fork pull request', Time.utc(2026, 8, 5, 12, 0, 0),
        Struct.new(:ref).new('main'), Struct.new(:repo).new(repo)
      )
    end
    installation_client.define_singleton_method(:search_issues) do |*, page:, **|
      Struct.new(:items).new([])
    end
    installation_client.define_singleton_method(:update_check_run) do |*args, **kwargs|
      calls << { name: :update_check_run, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:add_comment) do |*args, **kwargs|
      calls << { name: :add_comment, args: args, kwargs: kwargs }
    end
    installation_client.define_singleton_method(:create_issue) do |*args, **kwargs|
      calls << { name: :create_issue, args: args, kwargs: kwargs }
      Struct.new(:number, :html_url).new(1, 'https://github.com/octocat/example/issues/1')
    end

    @scanner = Sinatra::Application.new!
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @files << Struct.new(:filename, :patch).new('app.js', "@@ -0,0 +1 @@\n+// TODO: Fix this\n")
  end

  def test_a_fork_cannot_enable_issue_creation_through_its_own_configuration
    run_check

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  def test_a_fork_cannot_create_issues_through_the_check_run_action
    run_check(requested_action: 'create_issues')

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  def test_forks_do_not_create_issues_unless_the_base_configuration_opts_in
    @base_config = "todo-pr-checker:\n  create_issues: always\n"

    run_check

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  def test_the_base_configuration_decides_whether_a_fork_may_create_issues
    @base_config = "todo-pr-checker:\n  create_issues: always\n  create_issues_from_forks: true\n"
    @head_config = "todo-pr-checker:\n  create_issues: always\n"

    run_check

    assert_equal 1, @calls.count { |call| call[:name] == :create_issue }
  end

  def test_a_fork_disabling_issue_creation_is_respected
    # The fork can only ever reduce what happens, never enable issue creation the base branch did not ask for
    @base_config = "todo-pr-checker:\n  create_issues: always\n  create_issues_from_forks: true\n"
    @head_config = "todo-pr-checker: {}\n"

    run_check

    refute @calls.any? { |call| call[:name] == :create_issue }
  end

  def test_a_pull_request_from_the_same_repository_does_not_need_the_fork_option
    @head_repo = 'octocat/example'

    run_check

    assert_equal 1, @calls.count { |call| call[:name] == :create_issue }
  end

  private

  def run_check(requested_action: nil)
    arguments = {
      full_repo_name: 'octocat/example',
      pull_number: 7,
      head_sha: 'head-sha',
      check_run_id: 123
    }
    arguments[:requested_action] = requested_action if requested_action
    ORIGINAL_INITIATE_CHECK_RUN.bind_call(@scanner, **arguments)
  end
end

class RequestedActionRoutingTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
  end

  def test_create_issues_action_is_routed_with_the_existing_check_run
    payload = {
      'action' => 'requested_action',
      'repository' => { 'full_name' => 'octocat/example' },
      'requested_action' => { 'identifier' => 'create_issues' },
      'check_run' => {
        'id' => 987,
        'app' => { 'id' => ENV.fetch('GITHUB_APP_IDENTIFIER').to_i },
        'head_sha' => 'head-sha',
        'pull_requests' => [{ 'number' => 7 }]
      }
    }

    context = @scanner.send(:get_webhook_event_context, 'check_run', payload)

    assert_equal :check_run_requested_action, context[:type]
    assert_equal 987, context[:check_run_id]
    assert_equal 7, context[:pull_number]
  end

  def test_unknown_requested_actions_are_ignored
    payload = {
      'action' => 'requested_action',
      'repository' => { 'full_name' => 'octocat/example' },
      'requested_action' => { 'identifier' => 'something_else' },
      'check_run' => {
        'id' => 987,
        'app' => { 'id' => ENV.fetch('GITHUB_APP_IDENTIFIER').to_i },
        'head_sha' => 'head-sha',
        'pull_requests' => [{ 'number' => 7 }]
      }
    }

    assert_nil @scanner.send(:get_webhook_event_context, 'check_run', payload)
  end

  def test_requested_action_identifier_is_passed_through
    payload = {
      'action' => 'requested_action',
      'repository' => { 'full_name' => 'octocat/example' },
      'requested_action' => { 'identifier' => 'create_issues' },
      'check_run' => {
        'id' => 987,
        'app' => { 'id' => ENV.fetch('GITHUB_APP_IDENTIFIER').to_i },
        'head_sha' => 'head-sha',
        'pull_requests' => [{ 'number' => 7 }]
      }
    }

    context = @scanner.send(:get_webhook_event_context, 'check_run', payload)

    assert_equal 'create_issues', context[:requested_action]
  end
end

class IssueDescriptionSourceTest < Minitest::Test
  def setup
    @scanner = Sinatra::Application.new!
    @config_file = Struct.new(:content).new(Base64.strict_encode64("todo-pr-checker:\n  check_inline_comments: true\n"))
    config_file = @config_file
    installation_client = Object.new
    installation_client.define_singleton_method(:contents) { |*| config_file }
    @scanner.instance_variable_set(:@installation_client, installation_client)
    @options = @scanner.send(:get_app_options, 'octocat/example', 'head-sha')
  end

  def test_inline_comment_excerpt_excludes_the_code_before_the_comment
    changes = { 'example.js' => [{ line: 1, text: 'todoList.push(item); // TODO drop the legacy branch' }] }

    todo_changes, = @scanner.send(:check_for_todos, changes, @options)
    title = @scanner.send(:create_issue_title, 'example.js', todo_changes.fetch('example.js').first)

    assert_equal '[todo] example.js:1 - drop the legacy branch', title
  end

  def test_multiline_comment_excerpt_uses_the_comment_text
    changes = {
      'example.js' => [
        { line: 1, text: 'const value = true; /* start' },
        { line: 2, text: 'TODO finish the migration' },
        { line: 3, text: '*/' }
      ]
    }
    options = @options.merge('multiline_comments' => true)

    todo_changes, = @scanner.send(:check_for_todos, changes, options)
    title = @scanner.send(:create_issue_title, 'example.js', todo_changes.fetch('example.js').first)

    assert_equal '[todo] example.js:2 - finish the migration', title
  end

  def test_self_closing_block_comment_excerpt_drops_the_closing_delimiter
    changes = { 'example.js' => [{ line: 4, text: 'const flag = true; /* TODO remove the flag */' }] }

    todo_changes, = @scanner.send(:check_for_todos, changes, @options)
    title = @scanner.send(:create_issue_title, 'example.js', todo_changes.fetch('example.js').first)

    assert_equal '[todo] example.js:4 - remove the flag', title
  end
end
