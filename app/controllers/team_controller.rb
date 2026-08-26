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
