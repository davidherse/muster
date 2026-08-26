# Shared workspace (accounts with many seats) — design

Date: 2026-08-26. Approved in chat by David. Branch: `shared-workspace`.

## Problem

Muster scopes everything to a user: estimates, training documents, the
learned price book, the personal template, quantity norms, and onboarding
state all hang off `users`. A builder's team therefore cannot share anything —
each seat is an island. David wants one **account** with many users and a
single shared space inside it: all estimates, templates, training, book and
norms visible to and editable by everyone in the account.

## Decisions (from brainstorming)

- One account per user. No memberships table, no workspace switcher.
- Roles: `owner` and `member`. Exactly one owner per account. The owner
  renames the account and adds/removes seats. Everyone in the account can
  create/regenerate/delete estimates, upload/delete training documents, edit
  the account template, and (Muster admins only, as today) edit the global
  price book.
- Seats are added from a Team page; because there is no email delivery, the
  app shows the owner a set-password link to forward by hand.
- Sign-up with the invite code creates a **new** account with the signer as
  owner (for other builders). Existing beta users each get their own account
  via the migration.
- `admin` stays a global Muster-staff flag on users, unchanged.

## Data model

```
accounts
  name            string, null: false
  quantity_norms  json            (moved from users)
  onboarded_at    datetime        (moved from users)
  timestamps

users
  + account_id    integer, null: false, index
  + role          string, null: false, default "member"   # owner | member
  - quantity_norms, onboarded_at (dropped after copy)

estimates
  + account_id    integer, null: false, index
  user_id         becomes nullable — "created by"; kept for attribution

training_documents
  + account_id    integer, null: false, index
  user_id         becomes nullable — "uploaded by"

estimate_templates
  user_id  → account_id (rename; still nullable: nil = global default)

price_book_items
  user_id  → account_id (rename; still nullable: nil = base/market rows)
```

Associations:

- `Account has_many :users, :estimates, :training_documents, :estimate_templates, :price_book_items` (all `dependent: :destroy` except users, which is `dependent: :destroy` too — deleting an account is not exposed in UI). `Account#owner` = `users.find_by(role: "owner")`.
- `User belongs_to :account`; `role` validated in `%w[owner member]`; `owner?`.
- `Estimate belongs_to :account`; `belongs_to :user, optional: true` (creator). `TrainingDocument` the same.
- `EstimateTemplate belongs_to :account, optional: true`; `personal?` → `account?` (rename; keep `personal?` as an alias for one release is unnecessary — rename all call sites).
- `PriceBookItem belongs_to :account, optional: true`; `validates :account, presence: true, if: source_kind == "user"`. The `source_kind` value `"user"` is kept as a stored value (it means "this account's own rates") to avoid rewriting data; the scope is renamed `for_account`.
- `Current` gains `delegate :account, to: :user, allow_nil: true` (`Current.account`).

## Migration (one file, reversible where practical)

1. Create `accounts`. Add `users.account_id`, `users.role`; `estimates.account_id`; `training_documents.account_id`. Rename `estimate_templates.user_id → account_id` and `price_book_items.user_id → account_id` (indexes follow).
2. Data step, in Ruby inside the migration using lightweight `ActiveRecord::Base` subclasses (not app models): for each user, create an account named `user.name.presence || user.email_address` with `quantity_norms` and `onboarded_at` copied from the user; set `user.account_id`, `role = "owner"`; update `estimates`, `training_documents` where `user_id = user.id` → `account_id`; update `estimate_templates`, `price_book_items` where the renamed `account_id` column still holds the old user id → the new account id (do the rename after the data step to keep the mapping explicit, or map in place — implementer's choice, but the result must be verified by the counts check below).
3. Add NOT NULL on `users.account_id`, `estimates.account_id`, `training_documents.account_id`; make `estimates.user_id` and `training_documents.user_id` nullable; drop `users.quantity_norms`, `users.onboarded_at`.
4. `down` reverses structurally (recreate user columns, copy norms/onboarding back from the owner's account, rename columns back, drop accounts). Data loss on down is acceptable for non-owner attribution.

Pre-deploy check on faber: copy `storage/production.sqlite3` to a scratch path, run the migration against the copy, and assert: accounts = users; every estimate/training_document/user-book item/account template has an `account_id`; David's account holds 7 training documents, 1,736 user-book entries, the 47-section template, and norms. Only then migrate for real.

## Scoping changes

- Controllers: `Current.user.estimates` → `Current.account.estimates`; `Current.user.training_documents` → `Current.account.training_documents`. New estimates and training documents set both `account: Current.account` and `user: Current.user`.
- `EstimateTemplate`: `for_user(user)` → `for_account(account)`; `personal_for` → `active_for(account)`; `proposal_for(account)`; `available_to(account)`; `customise_for(account)` naming `"#{account.name} — #{name}"` with the existing collision suffix using `account.id`. `TemplateSynthesizer.new(account)`; its `unique_name` uses the account name. `SynthesizeTemplateJob.perform(account)`.
- `PriceBookItem.for_account(account)`, `from_training_doc(account, doc_id)`.
- `QuantityNorms.new(account)` reads `account.training_documents` and writes `account.quantity_norms`. `QuantityNorms.for_class(account, klass)`.
- Services that reached `@estimate.user` for template, price book, and norms (`PlanAnalyzer`, `EstimateGenerator#template`, `LineItemGenerator`, `EstimateReviewer`) use `@estimate.account`. `TrainingIngestor` uses `@doc.account`.
- Onboarding: `OnboardingController` and `SessionsController#create` use `Current.account.onboarded_at` / `account.estimates.none?`; `agree`/`skip` update the account. A new seat in an onboarded account lands on `/estimates`.
- Templates page copy: "Your template" → "Your workspace's template"; authorisation for an account template is "same account" (any role); global default stays admin-only.
- Estimates index gains a "By" column showing `estimate.user&.name` ("—" when the seat was removed).
- Layout sidebar: add "Team" (icon `users` — add an SVG path to `UiHelper::ICONS`) after Templates.

## Team page

Routes:

```ruby
resource :team, only: :show do
  patch :rename, on: :member          # owner: account name
  post  :members, to: "team#create"   # owner: add a seat
  delete "members/:id", to: "team#destroy", as: :member        # owner: remove
  post   "members/:id/reset_link", to: "team#reset_link", as: :member_reset_link  # owner
end
```

`TeamController`:

- `show`: account name (owner sees an inline rename form), member list: name, email, role, "password set" indicator (a seat created from the Team page has a random password the person never saw — track `users.password_set_at` set when a password is chosen via the reset form or at sign-up; nil means "hasn't set one yet"), and — owner only — a Remove button (not for the owner) and a "New set-password link" button. Any link generated during this request is shown once in a highlighted panel with the URL in a read-only input and a copy button (Stimulus `clipboard` controller, no dependency).
- `create` (owner only): `params.expect(user: [:name, :email_address])`; creates `account.users` with `role: "member"`, a random `SecureRandom.base58(24)` password, `activated_at: Time.current`; redirects to the Team page with the set-password link in `flash[:reset_link]` (URL built from `edit_password_url(user.password_reset_token)` — `default_url_options` must include the port for faber; see Environment).
- `reset_link` (owner only): regenerates a link for any member (including the owner themselves).
- `destroy` (owner only): refuses to remove the owner; otherwise `user.destroy` — sessions destroyed via association, estimates/training documents keep `account_id` and get `user_id: nil` (`has_many :estimates, dependent: :nullify` on User, likewise training documents).
- `rename` (owner only): `params.expect(account: [:name])`.
- Non-owners get the page read-only; any owner-only action by a member redirects to the Team page with an alert.

`PasswordsController#update` sets `password_set_at: Time.current` on success. `RegistrationsController#create` sets it at sign-up.

## Sign-up

`RegistrationsController#create` builds an `Account` (name from an optional `registration[company]` field, else `"#{name}'s workspace"`) and the user as `role: "owner"` inside one transaction. The registration form gains the optional Company field.

## Environment

`APP_HOST` is `faber.tail7154b6.ts.net` but the funnel port is 8443; `edit_password_url` needs the port. Add `APP_PORT` (optional) to `config/environments/production.rb` `default_url_options` (`port: ENV["APP_PORT"].presence`) and to `docs/SELF_HOSTING.md`'s env table; set `APP_PORT=8443` in faber's `.env`.

## Tests

- Fixtures: `accounts.yml` (`built`, `other`); `users.yml` gets `account:` and `role:` (one owner per account; users(:one) owner of `built`, users(:two) member of `built`, a new `outsider` owner of `other`). Every fixture/`create!` that sets `user:` on estimates, training documents, price-book items, or templates sets `account:` instead (plus `user:` for creator where relevant).
- Isolation: a member sees the owner's estimates, templates, training documents and book; an outsider sees none of them and gets 404 on direct URLs.
- Team: owner adds a seat (user created in the account, activated, `password_set_at` nil, reset link shown and works), member cannot add/remove/rename, owner cannot be removed, removing a member nullifies creator on their estimates and destroys their sessions, reset link regenerates.
- Registration creates an account with the signer as owner; Company field optional.
- Sign-in routing: new seat in an onboarded account → `/estimates`; fresh owner of a new account → onboarding.
- Services: `QuantityNorms`, `TemplateSynthesizer`, `TrainingIngestor`, generator/reviewer/analyzer tests re-pointed at accounts.
- Migration data step: covered by the faber dry run against a DB copy (documented in the plan), not by a unit test.

## Deploy (faber)

1. Dry-run migration on a copy of `storage/production.sqlite3`; verify counts.
2. `git pull` main after merge, add `APP_PORT=8443` to `.env`, `db:migrate` **before** restarting, `assets:precompile`, restart both units.
3. Console: move `brenden@builthr.com.au` and `paul@builthr.com.au` into David's account as members and delete their auto-created empty accounts; set `password_set_at` nil for both (they haven't chosen one) so the Team page shows them as pending.
4. Verify in the browser: Team page lists three seats; owner-only controls; member login sees David's estimates/template.

## Out of scope

Multiple accounts per user, ownership transfer, per-estimate permissions,
email invites, account deletion UI, per-role restrictions on templates/book.
