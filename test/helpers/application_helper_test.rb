# frozen_string_literal: true

require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "app_version returns the FrankMD version constant" do
    assert_equal FrankMD::VERSION, app_version
  end

  test "fork_version reads the trimmed contents of version.md" do
    expected = Rails.root.join("version.md").read.strip
    assert_equal expected, fork_version
  end
end
