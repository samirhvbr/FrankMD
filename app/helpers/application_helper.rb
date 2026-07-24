module ApplicationHelper
  def app_version
    FrankMD::VERSION
  end

  # Fork version, read from version.md at the app root. Returns nil on the
  # upstream project (no version.md), so the UI shows only the FrankMD version.
  def fork_version
    return @fork_version if defined?(@fork_version)

    path = Rails.root.join("version.md")
    @fork_version = (path.read.strip.presence if path.exist?)
  rescue StandardError
    @fork_version = nil
  end
end
