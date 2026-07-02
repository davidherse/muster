require "application_system_test_case"

class EstimateFlowTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  test "sign up, activate, log in, generate an estimate, download CSV" do
    # --- Sign up ---
    visit new_registration_url
    fill_in "Name", with: "Site Tester"
    fill_in "Email address", with: "tester@example.com"
    fill_in "Password", with: "password123", match: :prefer_exact
    fill_in "Confirm password", with: "password123"
    click_on "Sign up"
    assert_text "Check your email to activate your account"

    # --- Login blocked before activation ---
    fill_in "email_address", with: "tester@example.com"
    fill_in "password", with: "password123"
    click_on "Sign in"
    assert_text "isn't activated yet"

    # --- Activate via emailed token ---
    user = User.find_by!(email_address: "tester@example.com")
    visit activation_url(token: user.generate_token_for(:activation))
    assert_text "Your account is activated"

    # --- Log in ---
    fill_in "email_address", with: "tester@example.com"
    fill_in "password", with: "password123"
    click_on "Sign in"
    assert_text "Estimates"

    # --- Create an estimate (AI stubbed, job performed inline) ---
    click_on "Create your first estimate"
    fill_in "Project name", with: "6 Hilda St Renovation"
    attach_file "Architectural plans (PDF)", Rails.root.join("test/fixtures/files/plan.pdf")
    fill_in "Additional information", with: "Two storey renovation, mid-range finishes"
    fake = FakeAiClient.new
    Ai::Client.stub :new, fake do
      perform_enqueued_jobs do
        click_on "Generate estimate"
        assert_text "being generated"
      end
    end

    # --- Completed estimate shows totals and range ---
    visit current_url
    assert_text "Completed"
    assert_text "Estimate (ex. GST)"
    assert_text "Preliminaries"
    assert_text "Download CSV"

    # --- CSV download link points at the export (endpoint covered by integration tests) ---
    estimate = user.estimates.last
    assert_selector "a[href='#{csv_estimate_path(estimate)}']", text: "Download CSV"
  end
end
