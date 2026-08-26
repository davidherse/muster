# Shared Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One account with many users sharing a single space — estimates, template, training documents, learned price book and quantity norms belong to the account; an owner manages seats from a Team page with set-password links.

**Architecture:** Introduce `Account`; migrate additively (create accounts, stamp `account_id` everywhere, keep old columns), switch every scoping call site from user to account with `before_validation` inference of `account` from the creating user so existing `user.estimates.create!` call sites keep working, then drop the old user columns. Team management is a small `TeamController` over `Account#users` with roles `owner`/`member`.

**Tech Stack:** Rails 8.1, SQLite, Solid Queue, Hotwire (Stimulus via importmap), Tailwind, Minitest + fixtures, `FakeAiClient`.

**Spec:** `docs/superpowers/specs/2026-08-26-shared-workspace-design.md`

## Global Constraints

- Ruby 3.4.4; run everything from `~/Code/muster` with `PATH=/home/davidherse/.local/share/mise/installs/ruby/3.4.4/bin:$PATH`.
- `bin/rails test` must be green before every commit — the ONLY acceptable failure is the pre-existing `RegistrationsControllerTest#test_signup_creates_unactivated_user_and_sends_activation_email` (local `.env` invite code). Baseline: 151 runs.
- `bin/rubocop` (rails-omakase) clean on changed Ruby files.
- Roles are exactly `owner` and `member`; exactly one owner per account. `admin` on users stays a global Muster-staff flag and is not touched.
- `price_book_items.source_kind` keeps the stored value `"user"` (meaning "this account's own rates"); only the Ruby API is renamed.
- Deviation from spec, ruled by the controller: three small migrations (additive → switch → cleanup) instead of one, so the suite stays green between tasks; and no `APP_PORT` setting — controller-generated URLs already carry the funnel port (observed: redirects to `https://faber.tail7154b6.ts.net:8443/...`), and `edit_password_url` is generated in a controller.
- Fixture accounts: `built` (users `one` = owner, `two` = member) and `other` (users `outsider` = owner, `unactivated` = member). Neither is onboarded.
- Commit as you go on branch `shared-workspace` (created; git identity configured).

---

### Task 1: Accounts foundation (additive migration, models, fixtures)

**Files:**
- Create: `db/migrate/<ts>_create_accounts.rb`
- Create: `app/models/account.rb`
- Modify: `app/models/user.rb`, `app/models/current.rb`, `app/models/estimate.rb`, `app/models/training_document.rb`, `app/models/estimate_template.rb`, `app/models/price_book_item.rb`
- Create: `test/fixtures/accounts.yml`; Modify: `test/fixtures/users.yml`
- Create: `test/models/account_test.rb`; Modify: `test/models/user_test.rb` (create if absent)

**Interfaces:**
- Produces: `Account` (`has_many :users/:estimates/:training_documents/:estimate_templates/:price_book_items`, `#owner`, `#onboarded?`); `User#account`, `User#role`, `User#owner?`, `User::ROLES`; `Current.account`; `belongs_to :account` on Estimate (required), TrainingDocument (required), EstimateTemplate (optional), PriceBookItem (optional); Estimate/TrainingDocument infer `account` from `user` before validation; fixtures `accounts(:built)`, `accounts(:other)`, `users(:outsider)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/account_test.rb
require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "fixtures: built has one owner and one member" do
    built = accounts(:built)
    assert_equal users(:one), built.owner
    assert_equal %w[member owner], built.users.pluck(:role).sort
  end

  test "estimates created through a user land in the user's account" do
    estimate = users(:two).estimates.create!(name: "Shared job")
    assert_equal accounts(:built), estimate.account
    assert_includes accounts(:built).estimates, estimate
  end

  test "training documents created through a user land in the user's account" do
    doc = users(:two).training_documents.create!(name: "Doc")
    assert_equal accounts(:built), doc.account
  end

  test "current account follows the session user" do
    Current.session = users(:one).sessions.create!
    assert_equal accounts(:built), Current.account
  ensure
    Current.reset
  end

  test "role is validated" do
    user = users(:two)
    user.role = "boss"
    assert_not user.valid?
    assert users(:one).owner?
    assert_not users(:two).owner?
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/account_test.rb`
Expected: errors — no `accounts` fixture/table, `Account` undefined.

- [ ] **Step 3: Migration**

Run: `bin/rails generate migration CreateAccounts` and replace the generated file's body with:

```ruby
class CreateAccounts < ActiveRecord::Migration[8.1]
  # Plain table-backed classes so the migration doesn't depend on app models.
  class MigrationUser < ActiveRecord::Base; self.table_name = "users"; end
  class MigrationAccount < ActiveRecord::Base; self.table_name = "accounts"; end

  SCOPED_TABLES = %w[estimates training_documents estimate_templates price_book_items].freeze

  def up
    create_table :accounts do |t|
      t.string :name, null: false
      t.json :quantity_norms
      t.datetime :onboarded_at
      t.timestamps
    end
    add_reference :users, :account, index: true          # nullable until Task 3
    add_column :users, :role, :string, null: false, default: "member"
    SCOPED_TABLES.each { |table| add_reference table, :account, index: true }

    # One account per existing user, owned by that user, holding everything
    # they own today. Team members are folded in later by hand.
    MigrationUser.reset_column_information
    MigrationAccount.reset_column_information
    MigrationUser.find_each do |user|
      account = MigrationAccount.create!(
        name: user.name.presence || user.email_address,
        quantity_norms: user.quantity_norms,
        onboarded_at: user.onboarded_at
      )
      user.update_columns(account_id: account.id, role: "owner")
      SCOPED_TABLES.each do |table|
        execute "UPDATE #{table} SET account_id = #{account.id} WHERE user_id = #{user.id}"
      end
    end
  end

  def down
    SCOPED_TABLES.each { |table| remove_reference table, :account, index: true }
    remove_column :users, :role
    remove_reference :users, :account, index: true
    drop_table :accounts
  end
end
```

Run: `bin/rails db:migrate` (the test DB follows from schema on the next test run). Check `db/schema.rb` has the `accounts` table and the five `account_id` columns.

- [ ] **Step 4: Models and Current**

```ruby
# app/models/account.rb
# A builder's workspace: every seat in the account shares its estimates,
# template, training documents, learned price book and quantity norms.
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :estimates, dependent: :destroy
  has_many :training_documents, dependent: :destroy
  has_many :estimate_templates, dependent: :destroy
  has_many :price_book_items, dependent: :destroy

  validates :name, presence: true

  def owner
    users.find_by(role: "owner")
  end

  def onboarded?
    onboarded_at.present?
  end
end
```

`app/models/user.rb` — add after `has_secure_password …`:

```ruby
  ROLES = %w[owner member].freeze

  belongs_to :account
  validates :role, inclusion: { in: ROLES }

  def owner?
    role == "owner"
  end
```

`app/models/current.rb`:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  delegate :user, to: :session, allow_nil: true
  delegate :account, to: :user, allow_nil: true
end
```

`app/models/estimate.rb` — add below `belongs_to :user`:

```ruby
  belongs_to :account
  before_validation { self.account ||= user&.account }
```

`app/models/training_document.rb` — same two lines below `belongs_to :user`.

`app/models/estimate_template.rb` — add below `belongs_to :user, optional: true`:

```ruby
  belongs_to :account, optional: true
```

`app/models/price_book_item.rb` — add below `belongs_to :user, optional: true`:

```ruby
  belongs_to :account, optional: true
```

- [ ] **Step 5: Fixtures**

```yaml
# test/fixtures/accounts.yml
built:
  name: Built Homes

other:
  name: Other Builders
```

`test/fixtures/users.yml` — add `account:` and `role:` to every user and add `outsider`:

```yaml
<% password_digest = BCrypt::Password.create("password") %>

one:
  name: Dave Builder
  email_address: one@example.com
  admin: true
  account: built
  role: owner
  password_digest: <%= password_digest %>
  activated_at: <%= 1.day.ago %>

two:
  name: Sam Renovator
  email_address: two@example.com
  account: built
  role: member
  password_digest: <%= password_digest %>
  activated_at: <%= 1.day.ago %>

outsider:
  name: Olive Outsider
  email_address: outsider@example.com
  account: other
  role: owner
  password_digest: <%= password_digest %>
  activated_at: <%= 1.day.ago %>

unactivated:
  name: New Signup
  email_address: new@example.com
  account: other
  role: member
  password_digest: <%= password_digest %>
  activated_at: null
```

- [ ] **Step 6: Run tests**

Run: `bin/rails test test/models/account_test.rb && bin/rails test`
Expected: all pass (151 + 5). If any existing test fails because a record now needs an account, it is creating an estimate/training document without a user — give it `user: users(:one)`; report anything else.

- [ ] **Step 7: Rubocop and commit**

```bash
bin/rubocop app/models db/migrate test/models/account_test.rb
git add db app/models test/fixtures test/models/account_test.rb
git commit -m "Accounts: additive migration, model, fixtures — one account per existing user"
```

---

### Task 2: Scope everything to the account

**Files:**
- Modify: `app/models/estimate_template.rb`, `app/models/price_book_item.rb`
- Modify: `app/services/quantity_norms.rb`, `app/services/template_synthesizer.rb`, `app/services/training_ingestor.rb`, `app/services/line_item_generator.rb`, `app/services/estimate_reviewer.rb`, `app/services/plan_analyzer.rb`, `app/services/estimate_generator.rb`, `app/jobs/synthesize_template_job.rb`
- Modify: `app/controllers/estimates_controller.rb`, `app/controllers/training_documents_controller.rb`, `app/controllers/onboarding_controller.rb`, `app/controllers/templates_controller.rb`, `app/controllers/sessions_controller.rb`
- Modify: `app/views/templates/index.html.erb`, `app/views/estimates/new.html.erb`, `app/views/estimates/index.html.erb`
- Test: every file under `test/` that the mapping below touches, plus new isolation tests.

**Interfaces:**
- Consumes: Task 1.
- Produces: `EstimateTemplate.for_account(account)`, `.active_for(account)`, `.proposal_for(account)`, `.available_to(account)`, `#customise_for(account)`, `#account?`; `PriceBookItem.for_account(account)`, `.from_training_doc(account, doc_id)`; `QuantityNorms.new(account)/derive!(account)/for_class(account, klass)`; `TemplateSynthesizer.new(account, client:)`; `SynthesizeTemplateJob.perform(account)`; `LineItemGenerator.price_book_block(account)`. All controllers read `Current.account`.

- [ ] **Step 1: Write the failing isolation tests**

Append to `test/controllers/estimates_controller_test.rb` (replace the existing "cannot see another user's estimate" test with these two):

```ruby
  test "a member sees an estimate the owner created" do
    theirs = users(:two).estimates.create!(name: "Sam's job")
    get estimate_url(theirs)
    assert_response :success
    get estimates_url
    assert_match "Sam's job", response.body
  end

  test "cannot see another account's estimate" do
    other = users(:outsider).estimates.create!(name: "Theirs")
    get estimate_url(other)
    assert_response :not_found
    get estimates_url
    assert_no_match(/Theirs/, response.body)
  end

  test "index shows who created each estimate" do
    users(:two).estimates.create!(name: "Sam's job")
    get estimates_url
    assert_match "Sam Renovator", response.body
  end
```

Append to `test/controllers/templates_controller_test.rb`:

```ruby
  test "the account template is shared: a member can edit what the owner created" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Ours", account: accounts(:built), status: "active", sections: [ { "name" => "A" } ])
    get edit_template_url(mine)
    assert_response :success
    patch template_url(mine), params: { template: { name: "Ours v2", sections: [ { name: "B" } ] } }
    assert_redirected_to templates_url
    assert_equal "Ours v2", mine.reload.name
  end

  test "another account's template is not editable" do
    sign_in_as @user
    theirs = EstimateTemplate.create!(name: "Theirs", account: accounts(:other), status: "active", sections: [ { "name" => "A" } ])
    get edit_template_url(theirs)
    assert_redirected_to templates_url
  end
```

Append to `test/controllers/training_documents_controller_test.rb`:

```ruby
  test "training documents are shared across the account, not across accounts" do
    users(:two).training_documents.create!(name: "Sam's upload")
    users(:outsider).training_documents.create!(name: "Outsider upload")
    get training_documents_url
    assert_match "Sam's upload", response.body
    assert_no_match(/Outsider upload/, response.body)
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/estimates_controller_test.rb test/controllers/templates_controller_test.rb test/controllers/training_documents_controller_test.rb`
Expected: the new tests fail (member gets 404 / edit redirected / Sam's upload missing).

- [ ] **Step 3: Models**

`app/models/estimate_template.rb` — replace the user-based methods; the class now reads (keep `sections_form=`, `sections_must_be_named`, `section_names`, validations exactly as they are):

```ruby
  belongs_to :account, optional: true
  # (remove `belongs_to :user, optional: true`)

  scope :global, -> { where(account_id: nil) }

  def account?
    account_id.present?
  end
  # (remove personal?)

  # Agreeing a proposal makes it the account's template; any previous
  # account template is superseded.
  def activate!
    transaction do
      self.class.where(account: account).where.not(id: id).destroy_all if account?
      update!(status: "active")
    end
  end

  def self.active_for(account)
    active.where(account: account).order(updated_at: :desc).first
  end

  def self.proposal_for(account)
    proposed.find_by(account: account)
  end

  # The template an account's estimates are built on: its agreed template,
  # else the shared default.
  def self.for_account(account)
    return default unless account
    active_for(account) || default
  end

  def self.available_to(account)
    [ active_for(account), default ].compact
  end

  def customise_for(account)
    return nil if self.class.active_for(account)
    base = "#{account.name} — #{name}".truncate(120)
    base = "#{base} (#{account.id})" if self.class.exists?(name: base)
    self.class.create!(account: account, status: "active", name: base,
      description: "Customised from #{name}.", sections: sections.deep_dup)
  end
```

(`for_user`/`personal_for` are removed; grep the app for both and update every caller in this task.)

`app/models/price_book_item.rb`:

```ruby
  belongs_to :account, optional: true
  # (remove belongs_to :user)
  validates :account, presence: true, if: -> { source_kind == "user" }
  scope :for_account, ->(account) { where(source_kind: "user", account: account) }
  scope :from_training_doc, ->(account, doc_id) {
    tag = "training:#{doc_id}"
    for_account(account).where("source = ? OR source LIKE ?", tag, "#{tag} %")
  }
```

- [ ] **Step 4: Services and job**

`app/services/quantity_norms.rb`: rename every `user` → `account` (`self.derive!(account)`, `initialize(account)`, `@account.training_documents`, `@account.update!(quantity_norms: …)`, `@account.quantity_norms`, `self.for_class(account, project_class)` and its body). Update the header comment: "Stored on accounts.quantity_norms".

`app/services/template_synthesizer.rb`: `initialize(account, client:)`, `@account`; line 41 `@account.training_documents…`; line 86 `PriceBookItem.from_training_doc(@account, doc.id)`; `upsert_proposal`: `find_or_initialize_by(account: @account, status: "proposed")` and the description's count from `@account.training_documents`; `unique_name`: `"#{@account.name} — …"` and suffix `(#{@account.id})`.

`app/jobs/synthesize_template_job.rb`: `def perform(account)` → `TemplateSynthesizer.new(account).call`; update its comment.

`app/services/training_ingestor.rb`: line 83 `QuantityNorms.derive!(@doc.account)`; 188 and 217 `PriceBookItem.from_training_doc(@doc.account, @doc.id)`; 237 `account_id: @doc.account_id` (replacing `user_id: @doc.user_id`); 254 `SynthesizeTemplateJob.perform_later(@doc.account)`; comments "user's" → "account's".

`app/services/line_item_generator.rb`: `self.price_book_block(account = nil)` using `PriceBookItem.for_account(account)` (both occurrences on lines 70–71); line 325 `QuantityNorms.for_class(@estimate.account, …)`; lines 355–358 `account = @estimate.account; return nil unless account; … PriceBookItem.for_account(account)`.

`app/services/estimate_reviewer.rb`: lines 100 and 116 `LineItemGenerator.price_book_block(@estimate.account)`; line 378 `QuantityNorms.for_class(@estimate.account, …)`.

`app/services/plan_analyzer.rb` line 208 and `app/services/estimate_generator.rb` line 171: `EstimateTemplate.for_account(@estimate.account)`.

- [ ] **Step 5: Controllers**

`EstimatesController`: `index` scope `Current.account.estimates.recent_first`; `new` → `Current.account.estimates.new(user: Current.user, estimate_template: EstimateTemplate.for_account(Current.account))`; `create` → `Current.account.estimates.new(estimate_params.merge(user: Current.user))`, the guard `EstimateTemplate.available_to(Current.account).include?(…)`, fallback `EstimateTemplate.for_account(Current.account)`; `set_estimate` → `Current.account.estimates.find(params[:id])`.

`TrainingDocumentsController`: every `Current.user.training_documents` → `Current.account.training_documents`; `new`/`create` pass `user: Current.user` (`Current.account.training_documents.new(document_params.merge(user: Current.user))`); `destroy`: `PriceBookItem.from_training_doc(Current.account, document.id).delete_all` and `QuantityNorms.derive!(Current.account)`.

`OnboardingController`: `Current.user.training_documents` → `Current.account.training_documents` (all); `create_upload` passes `user: Current.user`; `template`/`status`: `EstimateTemplate.proposal_for(Current.account)` / `.proposed.where(account: Current.account)`; `SynthesizeTemplateJob.perform_later(Current.account)`; `agree`/`skip`: `Current.account.update!(onboarded_at: Time.current)` (replacing `Current.user.update!`).

`TemplatesController`: `EstimateTemplate.active_for(Current.account)` for `@personal` (rename the ivar to `@account_template` in controller and view), `.proposal_for(Current.account)` everywhere, `Current.user.training_documents` → `Current.account.training_documents`, `customise_for(Current.account)`, `SynthesizeTemplateJob.perform_later(Current.account)`; `authorise_edit!`: `allowed = @template.account? ? @template.account_id == Current.account.id : Current.user.admin?`. The `session[:template_rederive]` user-scoping stays keyed by `Current.user.id` (it's per browser session).

`SessionsController#create`: `if user.account.onboarded_at.nil? && user.account.estimates.none?` → onboarding.

- [ ] **Step 6: Views**

`app/views/templates/index.html.erb`: rename `@personal` → `@account_template`; copy: "Your template" → "Your workspace's template", "You don't have a personal template yet" → "Your workspace doesn't have its own template yet".

`app/views/estimates/new.html.erb`: `EstimateTemplate.available_to(Current.account)`.

`app/views/estimates/index.html.erb`: add a "By" column after "Status": header `<th class="<%= ui_table_head %> hidden md:table-cell">By</th>` and cell `<td class="<%= ui_table_cell %> hidden md:table-cell text-muted-foreground"><%= estimate.user&.name || "—" %></td>`.

- [ ] **Step 7: Re-point the tests**

Apply these exact substitutions across `test/` (grep for each; the counts are from the current tree):

| Find | Replace with |
|---|---|
| `TemplateSynthesizer.new(@user, ` | `TemplateSynthesizer.new(@user.account, ` |
| `TemplateSynthesizer.new(users(:two)` | `TemplateSynthesizer.new(users(:two).account` |
| `QuantityNorms.for_class(@user, ` | `QuantityNorms.for_class(@user.account, ` |
| `QuantityNorms.for_class(users(:two)` | `QuantityNorms.for_class(users(:two).account` |
| `QuantityNorms.derive!(users(:x))` / `.derive!(@user)` | `.derive!(users(:x).account)` / `.derive!(@user.account)` |
| `@user.reload.quantity_norms` / `users(:x).reload.quantity_norms` | `@user.account.reload.quantity_norms` / `users(:x).account.reload.quantity_norms` |
| `users(:two).reload.onboarded_at` | `accounts(:built).reload.onboarded_at` |
| `EstimateTemplate.create!(… user: users(:one) …)` | `… account: accounts(:built) …` |
| `EstimateTemplate.create!(… user: users(:two) …)` | `… account: accounts(:built) …` |
| `EstimateTemplate.create!(… user: @user …)` / `user: @admin` | `… account: accounts(:built) …` |
| `EstimateTemplate.find_by(user: users(:two))` | `EstimateTemplate.find_by(account: accounts(:built))` |
| `EstimateTemplate.for_user(x)` / `.personal_for(x)` | `.for_account(x.account)` / `.active_for(x.account)` (fixture users → `accounts(:built)`) |
| `PriceBookItem.create!(… user: … )` / `.for_user(user)` / `.from_training_doc(user, …)` | `account: user.account` / `.for_account(account)` / `.from_training_doc(account, …)` |
| `users(:one).estimates.create!` / `users(:two).training_documents.create!` | unchanged (account is inferred) |

Tests whose meaning changes because users `one` and `two` now share an account — rewrite, don't just re-point:
- `test/models/estimate_template_test.rb`: "available_to lists the user's personal template then the default, never others'" → the "other" template belongs to `accounts(:other)`, `mine` to `accounts(:built)`; call `available_to(accounts(:built))`. `customise_for` tests use `accounts(:built)` and assert the name `"Built Homes — Test Standard"`; the collision test uses a second account named `"Built Homes"` (`Account.create!(name: "Built Homes")`) and asserts the suffix ` (#{id})`.
- `test/controllers/templates_controller_test.rb`: "cannot edit another user's personal template" → create `theirs` with `account: accounts(:other)` (the shared-account case is the new test from Step 1). "index offers editing the default only to admins" is unchanged.
- `test/controllers/estimates_controller_test.rb`: "new lists only my personal template and the default as layouts" → `theirs` with `account: accounts(:other)`, `mine`/`proposal` with `account: accounts(:built)`; the server-side guard tests likewise (`theirs` in `other`).
- `test/controllers/onboarding_controller_test.rb`: `users(:two).reload.onboarded_at` → `accounts(:built).reload.onboarded_at`; `EstimateTemplate.find_by(user: users(:two))` → `find_by(account: accounts(:built))`; `EstimateTemplate.for_user(users(:two))` → `for_account(accounts(:built))`.
- `test/services/quantity_norms_test.rb`, `template_synthesizer_test.rb`, `training_ingestor_test.rb`: norms/proposals live on the account now — every `user.quantity_norms` read becomes `user.account.reload.quantity_norms`, every `EstimateTemplate.find_by(user:)` becomes `find_by(account:)`, `PriceBookItem` assertions filter by `account:`.

- [ ] **Step 8: Run the whole suite**

Run: `bin/rails test`
Expected: green (only the known registrations failure). `grep -rn "for_user\|personal_for\|personal?\|Current.user.estimates\|Current.user.training_documents\|\.user\.quantity_norms\|user.onboarded_at" app/` must return nothing.

- [ ] **Step 9: Rubocop and commit**

```bash
bin/rubocop app test
git add app test
git commit -m "Scope estimates, templates, training, price book and norms to the account"
```

---

### Task 3: Cleanup migration — constraints, creator nullability, drop moved columns

**Files:**
- Create: `db/migrate/<ts>_finish_account_scoping.rb`
- Modify: `app/models/user.rb`, `app/models/estimate.rb`, `app/models/training_document.rb`
- Test: `test/models/account_test.rb`

**Interfaces:**
- Produces: `users.account_id`, `estimates.account_id`, `training_documents.account_id` NOT NULL; `estimates.user_id`/`training_documents.user_id` nullable; `users.quantity_norms`, `users.onboarded_at`, `estimate_templates.user_id`, `price_book_items.user_id` gone; `User has_many :estimates/:training_documents, dependent: :nullify`; `Estimate`/`TrainingDocument belongs_to :user, optional: true`.

- [ ] **Step 1: Write the failing test**

Append to `test/models/account_test.rb`:

```ruby
  test "removing a seat keeps its work in the account, unattributed" do
    estimate = users(:two).estimates.create!(name: "Sam's job")
    doc = users(:two).training_documents.create!(name: "Sam's doc")
    users(:two).destroy!
    assert_nil estimate.reload.user
    assert_equal accounts(:built), estimate.account
    assert_nil doc.reload.user
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/account_test.rb`
Expected: fails (estimate destroyed with the user, or NOT NULL violation).

- [ ] **Step 3: Migration and models**

Run: `bin/rails generate migration FinishAccountScoping`; body:

```ruby
class FinishAccountScoping < ActiveRecord::Migration[8.1]
  def change
    change_column_null :users, :account_id, false
    change_column_null :estimates, :account_id, false
    change_column_null :training_documents, :account_id, false
    change_column_null :estimates, :user_id, true
    change_column_null :training_documents, :user_id, true
    remove_column :users, :quantity_norms, :json
    remove_column :users, :onboarded_at, :datetime
    remove_reference :estimate_templates, :user, index: true
    remove_reference :price_book_items, :user, index: true
  end
end
```

Run `bin/rails db:migrate`.

`app/models/user.rb`: `has_many :estimates, dependent: :nullify` and `has_many :training_documents, dependent: :nullify`; remove `has_many :price_book_items`.
`app/models/estimate.rb` and `app/models/training_document.rb`: `belongs_to :user, optional: true`.

- [ ] **Step 4: Run tests**

Run: `bin/rails test`
Expected: green. If any test references `users.onboarded_at`/`quantity_norms` or `price_book_items.user_id`, it was missed in Task 2 — fix it here.

- [ ] **Step 5: Rubocop and commit**

```bash
bin/rubocop app/models db/migrate test/models/account_test.rb
git add db app/models test
git commit -m "Finish account scoping: constraints, nullable creators, drop moved user columns"
```

---

### Task 4: Registration creates an account; password_set_at

**Files:**
- Create: `db/migrate/<ts>_add_password_set_at_to_users.rb`
- Modify: `app/controllers/registrations_controller.rb`, `app/controllers/passwords_controller.rb`, `app/views/registrations/new.html.erb`
- Test: `test/controllers/registrations_controller_test.rb`, `test/controllers/passwords_controller_test.rb`

**Interfaces:**
- Produces: `users.password_set_at` (datetime, nil = never chose a password); registration builds `Account` + owner; `registration[company]` optional.

- [ ] **Step 1: Write the failing tests**

In `test/controllers/registrations_controller_test.rb`, first pin the invite code so the tests don't depend on the developer's `.env` (this also fixes the long-standing local failure of "signup creates unactivated user…"):

```ruby
  setup do
    @original_invite_code = ENV["MUSTER_INVITE_CODE"]
    ENV["MUSTER_INVITE_CODE"] = "MUSTER-BETA"
  end

  teardown do
    ENV["MUSTER_INVITE_CODE"] = @original_invite_code
  end
```

Then append:

```ruby
  test "signup creates an account owned by the new user, named from company" do
    assert_difference "Account.count", 1 do
      post registration_url, params: { registration: { invite_code: "MUSTER-BETA", company: "Acme Builders" }, user: {
        name: "Ann", email_address: "ann@example.com", password: "password-123", password_confirmation: "password-123" } }
    end
    user = User.find_by!(email_address: "ann@example.com")
    assert user.owner?
    assert_equal "Acme Builders", user.account.name
    assert_not_nil user.password_set_at
  end

  test "signup without a company names the workspace after the person" do
    post registration_url, params: { registration: { invite_code: "MUSTER-BETA" }, user: {
      name: "Ann", email_address: "ann2@example.com", password: "password-123", password_confirmation: "password-123" } }
    assert_equal "Ann's workspace", User.find_by!(email_address: "ann2@example.com").account.name
  end
```

Append to `test/controllers/passwords_controller_test.rb`:

```ruby
  test "choosing a password records password_set_at" do
    user = users(:two)
    user.update_columns(password_set_at: nil)
    patch password_url(user.password_reset_token), params: { password: "brand-new-pass", password_confirmation: "brand-new-pass" }
    assert_redirected_to new_session_url
    assert_not_nil user.reload.password_set_at
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/registrations_controller_test.rb test/controllers/passwords_controller_test.rb`
Expected: `password_set_at` unknown / account count unchanged.

- [ ] **Step 3: Migration**

Run: `bin/rails generate migration AddPasswordSetAtToUsers`; body:

```ruby
class AddPasswordSetAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :password_set_at, :datetime
    execute "UPDATE users SET password_set_at = created_at"   # everyone so far chose their own
  end

  def down
    remove_column :users, :password_set_at
  end
end
```

Run `bin/rails db:migrate`.

- [ ] **Step 4: Controllers and view**

`RegistrationsController#create` — replace the body from `@user = User.new(user_params)` down to the `if @user.save` block with:

```ruby
    @user = User.new(user_params.merge(role: "owner", password_set_at: Time.current))
    unless valid_invite_code?
      @user.validate
      @user.errors.add(:base, "Muster is in closed beta — an invite code is required. Join the wait list on the homepage.")
      return render :new, status: :unprocessable_entity
    end
    @user.account = Account.new(name: params.dig(:registration, :company).to_s.strip.presence || "#{@user.name}'s workspace")
    if @user.save
      UserMailer.activation(@user).deliver_later
      redirect_to new_session_path, notice: "Almost there! Check your email to activate your account."
    else
      render :new, status: :unprocessable_entity
    end
```

(`@user.save` saves the new account through `belongs_to :account` autosave.)

`PasswordsController#update`: `if @user.update(params.permit(:password, :password_confirmation).merge(password_set_at: Time.current))`.

`app/views/registrations/new.html.erb`: after the name field add

```erb
        <div class="grid gap-2">
          <%= label_tag "registration[company]", "Company (optional)", class: ui_label %>
          <%= text_field_tag "registration[company]", params.dig(:registration, :company), placeholder: "Names your workspace", class: ui_input %>
        </div>
```

- [ ] **Step 5: Run tests, rubocop, commit**

```bash
bin/rails test && bin/rubocop app/controllers db/migrate test/controllers
git add db app/controllers app/views/registrations test/controllers
git commit -m "Sign-up creates the account; track when a user chose their password"
```

---

### Task 5: Team page

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/team_controller.rb`, `app/views/team/show.html.erb`, `app/javascript/controllers/clipboard_controller.js`
- Modify: `app/helpers/ui_helper.rb` (add `users` icon), `app/views/layouts/application.html.erb` (nav)
- Create: `test/controllers/team_controller_test.rb`

**Interfaces:**
- Consumes: `Account#owner`, `User#owner?`, `users.password_set_at`, `edit_password_url(token)`.
- Produces: routes `team_path`, `rename_team_path`, `team_members_path`, `team_member_path(user)`, `reset_link_team_member_path(user)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/team_controller_test.rb
require "test_helper"

class TeamControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @member = users(:two)
  end

  test "requires authentication" do
    get team_url
    assert_redirected_to new_session_url
  end

  test "owner sees members with controls" do
    sign_in_as @owner
    get team_url
    assert_response :success
    assert_match "Sam Renovator", response.body
    assert_no_match(/Olive Outsider/, response.body)
    assert_select "form[action=?]", team_members_path
    assert_select "form[action=?]", team_member_path(@member)
    assert_select "form[action=?]", team_member_path(@owner), count: 0
  end

  test "member sees the team read-only" do
    sign_in_as @member
    get team_url
    assert_response :success
    assert_select "form[action=?]", team_members_path, count: 0
    assert_select "form[action=?]", team_member_path(@member), count: 0
  end

  test "owner adds a seat and gets a set-password link that works" do
    sign_in_as @owner
    assert_difference "accounts(:built).users.count", 1 do
      post team_members_url, params: { user: { name: "Brenden", email_address: "brenden@example.com" } }
    end
    seat = User.find_by!(email_address: "brenden@example.com")
    assert_equal accounts(:built), seat.account
    assert_equal "member", seat.role
    assert seat.activated?
    assert_nil seat.password_set_at
    assert_redirected_to team_url
    follow_redirect!
    link = response.body[%r{https?://[^"<\s]+/passwords/[^"<\s]+/edit}]
    assert link, "set-password link not shown"
    get link
    assert_response :success
  end

  test "member cannot add, remove, rename, or reset" do
    sign_in_as @member
    assert_no_difference "User.count" do
      post team_members_url, params: { user: { name: "X", email_address: "x@example.com" } }
    end
    assert_redirected_to team_url
    delete team_member_url(@owner)
    assert_redirected_to team_url
    assert User.exists?(@owner.id)
    patch rename_team_url, params: { account: { name: "Hijacked" } }
    assert_equal "Built Homes", accounts(:built).reload.name
    post reset_link_team_member_url(@owner)
    assert_redirected_to team_url
  end

  test "owner cannot be removed; removing a member keeps their estimates" do
    sign_in_as @owner
    estimate = @member.estimates.create!(name: "Sam's job")
    delete team_member_url(@owner)
    assert User.exists?(@owner.id)
    delete team_member_url(@member)
    assert_redirected_to team_url
    assert_not User.exists?(@member.id)
    assert_nil estimate.reload.user
    assert_equal accounts(:built), estimate.account
  end

  test "owner regenerates a set-password link for any member" do
    sign_in_as @owner
    post reset_link_team_member_url(@member)
    assert_redirected_to team_url
    follow_redirect!
    assert_match %r{/passwords/[^"<\s]+/edit}, response.body
  end

  test "owner renames the workspace" do
    sign_in_as @owner
    patch rename_team_url, params: { account: { name: "Built Homes Pty Ltd" } }
    assert_redirected_to team_url
    assert_equal "Built Homes Pty Ltd", accounts(:built).reload.name
  end

  test "cannot remove a user from another account" do
    sign_in_as @owner
    delete team_member_url(users(:outsider))
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/team_controller_test.rb`
Expected: routing errors (`team_url` undefined).

- [ ] **Step 3: Routes, controller, views, icon, nav**

`config/routes.rb` — after the `resources :templates` block:

```ruby
  resource :team, only: :show do
    patch :rename                                   # rename_team_path
  end
  post   "team/members",                to: "team#create",     as: :team_members
  delete "team/members/:id",            to: "team#destroy",    as: :team_member
  post   "team/members/:id/reset_link", to: "team#reset_link", as: :reset_link_team_member
```

`app/controllers/team_controller.rb`:

```ruby
# The account's seats. Everyone can see who is in the workspace; only the
# owner adds/removes seats, renames the workspace, and issues set-password
# links (there is no email delivery — the owner forwards the link).
class TeamController < ApplicationController
  before_action :require_owner!, except: :show
  before_action :set_member, only: %i[ destroy reset_link ]

  def show
    @account = Current.account
    @members = @account.users.order(Arel.sql("CASE role WHEN 'owner' THEN 0 ELSE 1 END"), :name)
    @reset_link = flash[:reset_link]
  end

  def create
    password = SecureRandom.base58(24)
    seat = Current.account.users.new(seat_params.merge(
      role: "member", activated_at: Time.current, password: password, password_confirmation: password))
    if seat.save
      flash[:reset_link] = edit_password_url(seat.password_reset_token)
      redirect_to team_path, notice: "#{seat.name} has a seat. Send them the link below to set their password."
    else
      redirect_to team_path, alert: seat.errors.full_messages.to_sentence
    end
  end

  def reset_link
    flash[:reset_link] = edit_password_url(@member.password_reset_token)
    redirect_to team_path, notice: "New set-password link for #{@member.name} — it lasts #{@member.password_reset_token_expires_in.inspect}."
  end

  def destroy
    return redirect_to team_path, alert: "The owner can't be removed." if @member.owner?
    @member.destroy!
    redirect_to team_path, notice: "#{@member.name} no longer has a seat. Their estimates stay with the workspace."
  end

  def rename
    if Current.account.update(params.expect(account: [ :name ]))
      redirect_to team_path, notice: "Workspace renamed."
    else
      redirect_to team_path, alert: Current.account.errors.full_messages.to_sentence
    end
  end

  private

  def set_member
    @member = Current.account.users.find(params[:id])
  end

  def require_owner!
    redirect_to team_path, alert: "Only the workspace owner can do that." unless Current.user.owner?
  end

  def seat_params
    params.expect(user: [ :name, :email_address ])
  end
end
```

`app/views/team/show.html.erb`:

```erb
<div class="mx-auto md:w-2/3 w-full">
  <h1 class="font-semibold text-3xl tracking-tight mb-2">Team</h1>
  <p class="text-muted-foreground mb-6 text-sm">Everyone in <%= @account.name %> shares the same estimates, template, training and price book.</p>

  <% if @reset_link %>
    <div class="<%= ui_alert %> mb-6" data-controller="clipboard">
      <p class="font-medium mb-2">Send this set-password link (valid for 2 days, single use):</p>
      <div class="flex items-center gap-2">
        <input type="text" readonly value="<%= @reset_link %>" data-clipboard-target="source" class="<%= ui_input %> font-mono text-xs">
        <button type="button" data-action="clipboard#copy" class="<%= ui_button(variant: :outline, size: :sm) %>">Copy</button>
      </div>
    </div>
  <% end %>

  <section class="<%= ui_card %> mb-6 overflow-hidden">
    <div class="<%= ui_card_header %>">
      <h2 class="<%= ui_card_title %>"><%= @account.name %></h2>
      <p class="<%= ui_card_description %>"><%= pluralize(@members.size, "seat") %></p>
      <% if Current.user.owner? %>
        <%= form_with model: @account, scope: :account, url: rename_team_path, method: :patch, class: "flex items-center gap-2 mt-2" do |f| %>
          <%= f.text_field :name, required: true, class: "#{ui_input} max-w-xs" %>
          <%= f.submit "Rename", class: ui_button(variant: :outline, size: :sm) %>
        <% end %>
      <% end %>
    </div>
    <table class="<%= ui_table %>">
      <thead><tr class="<%= ui_table_header_row %>">
        <th class="<%= ui_table_head %> px-5">Name</th><th class="<%= ui_table_head %>">Email</th><th class="<%= ui_table_head %>">Role</th><th class="<%= ui_table_head %>">Password</th><th class="<%= ui_table_head %> px-5"></th>
      </tr></thead>
      <tbody>
        <% @members.each do |member| %>
          <tr class="<%= ui_table_row %>">
            <td class="<%= ui_table_cell %> px-5 font-medium"><%= member.name %></td>
            <td class="<%= ui_table_cell %> text-muted-foreground"><%= member.email_address %></td>
            <td class="<%= ui_table_cell %>"><span class="<%= ui_badge(variant: member.owner? ? :default : :outline) %>"><%= member.role %></span></td>
            <td class="<%= ui_table_cell %> text-muted-foreground"><%= member.password_set_at ? "set" : "not set yet" %></td>
            <td class="<%= ui_table_cell %> px-5 text-right">
              <% if Current.user.owner? %>
                <div class="flex justify-end gap-2">
                  <%= button_to "New link", reset_link_team_member_path(member), class: ui_button(variant: :ghost, size: :sm) %>
                  <% unless member.owner? %>
                    <%= button_to "Remove", team_member_path(member), method: :delete, data: { turbo_confirm: "Remove #{member.name}'s seat? Their estimates stay with the workspace." }, class: ui_button(variant: :destructive, size: :sm) %>
                  <% end %>
                </div>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </section>

  <% if Current.user.owner? %>
    <section class="<%= ui_card %> p-6">
      <h2 class="<%= ui_card_title %> mb-4">Add a seat</h2>
      <%= form_with scope: :user, url: team_members_path, class: "grid gap-4 md:grid-cols-3" do |f| %>
        <div class="grid gap-2"><%= f.label :name, class: ui_label %><%= f.text_field :name, required: true, class: ui_input %></div>
        <div class="grid gap-2"><%= f.label :email_address, "Email", class: ui_label %><%= f.email_field :email_address, required: true, class: ui_input %></div>
        <div class="flex items-end"><%= f.submit "Add seat", class: ui_button %></div>
      <% end %>
      <p class="text-xs text-muted-foreground mt-3">You'll get a set-password link to send them — Muster doesn't send email on this server.</p>
    </section>
  <% end %>
</div>
```

`app/javascript/controllers/clipboard_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Copies the source input's value; falls back to selecting it when the
// clipboard API is unavailable (non-secure context).
export default class extends Controller {
  static targets = ["source"]

  async copy(event) {
    const value = this.sourceTarget.value
    try {
      await navigator.clipboard.writeText(value)
      event.currentTarget.textContent = "Copied"
    } catch {
      this.sourceTarget.select()
    }
  }
}
```

`app/helpers/ui_helper.rb` — add to `ICONS`:

```ruby
    "users" => '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
```

`app/views/layouts/application.html.erb` nav array — add `[ "Team", team_path, "users" ]` after the Templates entry.

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/team_controller_test.rb && bin/rails test`
Expected: green. (`flash[:reset_link]` survives one redirect; `follow_redirect!` renders it.)

- [ ] **Step 5: Rubocop and commit**

```bash
bin/rubocop app/controllers/team_controller.rb app/helpers/ui_helper.rb config/routes.rb test/controllers/team_controller_test.rb
git add config/routes.rb app/controllers/team_controller.rb app/views/team app/javascript/controllers/clipboard_controller.js app/helpers/ui_helper.rb app/views/layouts/application.html.erb test/controllers/team_controller_test.rb
git commit -m "Team page: seats, owner controls, set-password links"
```

---

### Task 6: Docs, PR, dry-run migration, deploy, fold seats

**Files:**
- Modify: `docs/SELF_HOSTING.md` (a short "Team / seats" note under Notes: how to add seats and that links are forwarded by hand).

- [ ] **Step 1: Docs + final verification**

Add to `docs/SELF_HOSTING.md` Notes: "**Seats:** the workspace owner adds people from the Team page; because there is no email, it shows a set-password link (2 days) to forward by hand." Then `bin/rails test && bin/rubocop`, commit "Self-hosting notes: adding seats from the Team page".

- [ ] **Step 2: Push and PR**

```bash
git push -u origin shared-workspace
gh pr create --title "Shared workspace: one account, many seats" --body "$(cat <<'EOF'
## Summary
- `Account` owns what a builder's team shares: estimates, the template, training documents, the learned price book and quantity norms; users belong to one account with role `owner` or `member`.
- Three migrations: create accounts and stamp `account_id` (one account per existing user, owned by them), switch every scoping call site to the account, then drop the moved user columns and make creators nullable. Existing beta users keep exactly what they had.
- Team page (`/team`): seats with owner-only add/remove/rename and copyable set-password links (no email on self-hosted instances). Removing a seat keeps their estimates, unattributed.
- Sign-up creates a new account (optional Company field).

Design: `docs/superpowers/specs/2026-08-26-shared-workspace-design.md`

## Deploy notes
- `db:migrate` BEFORE restarting web and jobs; migrations are safe on SQLite and reversible.
- Existing users become owners of their own account; fold team members in via console if they already exist as separate users.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Dry-run the migrations on a copy of faber's database**

```bash
cd ~/muster && git fetch origin && git checkout shared-workspace
cp storage/production.sqlite3 /tmp/claude-1000/-home-davidherse-Code-muster/6043e42f-002e-4b84-9308-cfa68758f7b0/scratchpad/dryrun.sqlite3
export PATH=/home/davidherse/.local/share/mise/installs/ruby/3.4.4/bin:/usr/local/bin:/usr/bin:/bin RAILS_ENV=production
export DATABASE_URL=sqlite3:/tmp/claude-1000/-home-davidherse-Code-muster/6043e42f-002e-4b84-9308-cfa68758f7b0/scratchpad/dryrun.sqlite3
bin/rails db:migrate
bin/rails runner 'puts({ accounts: Account.count, users: User.count, david: (a = User.find_by!(email_address: "david@mapulus.com").account; { name: a.name, docs: a.training_documents.count, book: PriceBookItem.for_account(a).count, template_sections: EstimateTemplate.active_for(a)&.sections&.size, norms: a.quantity_norms.present?, onboarded: a.onboarded? }), unscoped: { estimates: Estimate.where(account_id: nil).count, docs: TrainingDocument.where(account_id: nil).count } }.inspect)'
```

Expected: `accounts: 3, users: 3`, David's account: 7 docs, 1736 book entries, 47 sections, norms true, onboarded true; unscoped counts 0. If `DATABASE_URL` does not override the multi-db config, instead point a temporary `config/database.yml` production `primary` at the copy for the dry run and restore it after. Do not proceed until the counts match.

- [ ] **Step 4: Deploy for real (branch, before merge)**

```bash
cd ~/muster && bundle install && bin/rails db:migrate && bin/rails assets:precompile
sudo systemctl restart muster-web muster-jobs
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: faber.tail7154b6.ts.net" localhost:3000/up   # 200
```

- [ ] **Step 5: Fold Brenden and Paul into David's account**

```bash
bin/rails runner '
david = User.find_by!(email_address: "david@mapulus.com")
%w[brenden@builthr.com.au paul@builthr.com.au].each do |email|
  u = User.find_by!(email_address: email)
  old = u.account
  u.update!(account: david.account, role: "member", password_set_at: nil)
  old.destroy! if old != david.account && old.users.none?
end
david.account.update!(name: "Built Homes")
puts david.account.users.pluck(:email_address, :role).inspect, Account.count'
```

Expected: three users in one account (David owner), `Account.count == 1`.

- [ ] **Step 6: Verify in the browser**

Sign in as David: `/team` lists three seats with owner controls, "not set yet" for Brenden and Paul; generate a new link for Paul and confirm it opens the reset form; `/templates` still shows the 47-section template; `/estimates` shows the "By" column. Then merge the PR (`gh pr merge --merge`), and switch `~/muster` back to `main` (`git checkout main && git pull`).
