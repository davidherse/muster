require "test_helper"

# A stale chromedriver on PATH (e.g. from Homebrew) breaks Selenium; hide it so
# Selenium Manager downloads a driver matching the installed Chrome.
ENV["PATH"] = ENV["PATH"].split(File::PATH_SEPARATOR)
  .reject { |dir| File.exist?(File.join(dir, "chromedriver")) }
  .join(File::PATH_SEPARATOR)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]
end
