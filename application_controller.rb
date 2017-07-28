class ApplicationController < ActionController::Base
  protect_from_forgery with: :null_session, if: Proc.new { |c| c.request.format == 'application/json' }
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from CanCan::AccessDenied, with: :access_denied

  ## Filters
  skip_before_action :verify_authenticity_token, if: Proc.new { |c| c.request.format == 'application/json' }
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :store_location, :get_time_zone, :get_new_user, :get_newsletter, :get_static_page, :check_profile, :trial_expired
  ## Helper Methods
  helper_method :current_role, :current_plan, :current_company, :minimum_tokens, :user_permission, :remaining_days, :check_site_due_soon, :check_site_item_due_soon,:current_permissions,:permissed_sites,:permissed_tabs

  def current_role
    if user_signed_in?
      @current_role ||= current_user.roles.pluck(:name)
    end
  end

  def current_plan
    if user_signed_in?
      if current_role.include? "manager"
        @current_plan ||= current_user.company.plan
      else
        @current_plan ||= current_user.plan
      end
    else
      ""
    end
  end

  def current_company
    if user_signed_in?
      if current_role.include? "manager"
        @current_company ||= current_user.company
      else
        ""
      end
    else
      ""
    end
  end

  def minimum_tokens
    @minimum_tokens ||= MinumumToken.last.tokens rescue 40
  end

  def user_permission(permission)
    if ((current_role.include? "manager") && current_user.permissions.present? && (current_user.permissions.include? permission)) || (current_role.include? "company")
      true
    else
      false
    end
  end

  def check_user_permission(permission)
    if !user_permission(permission)
      redirect_to root_path
    end
  end

  def current_permissions
    if (current_role.include? "manager")
      # @current_permissions ||= current_user.user_permissions.map{|i| i.permission_id}
      @current_permissions=Permission.find(current_user.user_permissions.map{|i| i.permission_id}).map{|i| i.name}
    end
  end

  def permissed_sites
    if (current_role.include? "manager")
      current_user.user_permissions.map{|i| i.site_id}.uniq
    end
  end

  def permissed_tabs
    if (current_role.include? "manager")
      current_user.user_permissions.map{|i| i.site_tab_id}.uniq
      #@permissed_tabs||=current_user.user_permissions.map{|i| SiteTab.find(i.site_tab_id).name rescue nil}.uniq.compact
      # @permissed_tabs ||= current_user.user_permissions.map{|i| i.site_tab_id}.uniq
    end
  end
  def store_location
    return unless request.get?
    if (request.path != "/" &&
        request.path != "/users/sign_in" &&
        request.path != "/users/sign_up" &&
        request.path != "/users/password/new" &&
        request.path != "/users/password/edit" &&
        request.path != "/users/confirmation/new" &&
        request.path != "/users/sign_out" &&
        request.path != "/users/retrieve_password/new" &&
        !(request.path.include? "/admin") &&
        !request.xhr?)
      session[:previous_url] = request.fullpath
    end
  end

  def get_time_zone
    Time.zone = current_user.time_zone if user_signed_in? && current_user.time_zone.present?
  end

  def get_new_user
    @new_user = User.new if !user_signed_in?
  end

  def get_newsletter
    @newsletter = Newsletter.new
  end

  def get_static_page
    @static_page ||= StaticPage.last
  end

  def get_trial_period
    @trial_period ||= TrialPeriod.last
  end

  def get_unread_notifications(user)
    unread_notifications = (user.upload_notifications.unread + user.notifications.unread).sort_by(&:created_at).reverse rescue []
    # unread_count = unread_notifications.size
    # read_notifications = user.upload_notifications.read.last(unread_count < 30 ? 30 - unread_count : 0)
    # (unread_notifications + read_notifications).sort_by {|notification| notification.id}.reverse
  end

  def publish_notification(notification, user)
    unread_notifications = user.unread_notifications + 1
    user.update_column(:unread_notifications, unread_notifications)
    PrivatePub.publish_to "/unread_notifications/#{notification.user_id}", "jQuery('#unread_notifications_count').html('<span class='notifications'><%= unread_notifications %></span>'); jQuery('#unread_notifications').html('<%= j(render partial: 'sites/unread_notifications', locals: { unread_notifications: get_unread_notifications(user)}) %>');"
  end

  def get_frequencies
    @frequencies = Frequency.where(visible: true).order("id ASC")
  end

  def check_site_due_soon(site)
    (site.compliant_status == "due_soon") ? true : false
  end

  def check_site_item_due_soon(site_item)
    # !site_item.compliant? && (DateTime.now.in_time_zone >= (site_item.due_date.in_time_zone - site_item.due_soon.send(site_item.due_soon_duration))) && (DateTime.now.in_time_zone <= site_item.due_date.in_time_zone) ? true : false rescue nil
    (site_item.compliant_status == "due_soon") ? true : false
  end

  def check_profile
    # if current_user.present? && !current_user.first_name.present?
      # redirect_to users_update_path
    # end
  end

  def after_sign_in_path_for(resource)
    if resource.class.name == "User"
      if current_user.sign_in_count == 1
        # users_update_path
        root_path
      else
        # session[:previous_url] || root_path
        root_path
      end
    else
      admin_dashboard_path
    end
  end

  def after_sign_up_path_for(resource)
    resource.class.name == "User" ? new_user_session_path : admin_dashboard_path
  end

  def after_sign_out_path_for(resource)
    session[:previous_url] = nil
    root_path
  end

  def check_credits
    # if !current_user.admin? && (current_user.credits < 1)
    #   redirect_to root_path(credits: 0)
    # end
  end

  def check_subscription
    authorized = true
    if (remaining_days <= 0) && !current_user.admin?
      if !current_user.plan.present?
        authorized = false
      end
    end
    authorized
  end

  # Find the remaining trial days for the user
  def remaining_days
    period = 14
    trial_period = get_trial_period
    if trial_period.present?
      if current_plan.present?
        period = 0
      else
        period = trial_period.period
      end
    end
    @remaining_days ||= ((current_user.created_at.in_time_zone + period.days).in_time_zone.to_date - Date.today.in_time_zone.to_date).round
  end

  def trial_expired
    #   unless current_plan ||  current_user.contractor_plan
    #     unless current_user.roles.include? "contractor_enterprise"
    #       redirect_to pricing_path
    #     end 
    #   else
    if current_user.present? && (current_role.include? "company") && !current_user.admin?
      plan = current_user.plan
      if (remaining_days <= 0) && !plan.present?
        redirect_to pricing_path(trial_expired: 1), notice: "Your Trail Period has Expired. Please Subscribe to continue."
      elsif plan.present?
        plan_expired = true
        transaction_detail = current_user.transaction_details.where(plan_id: plan.id).order("id ASC").last
        if !plan.price.present? || (transaction_detail.present? && ((transaction_detail.created_at.in_time_zone + plan.time_duration.send(plan.time_duration_postfix)) > DateTime.now.in_time_zone))
          plan_expired = false
        end
        if plan_expired
          redirect_to pricing_path(plan_expired: 1), notice: "Your Plan Period has Expired. Please Renew or Upgrade to continue."
        end
      end
    elsif current_user.present? && (current_role.include? "manager") && !current_user.admin?
      if current_user.additional_login_payment_at.present? && ((current_user.additional_login_payment_at.in_time_zone + 1.month).in_time_zone < DateTime.now.in_time_zone)
        redirect_to pricing_path(login_expired: 1), notice: "Your Login Period has Expired. Please ask your Company to Renew."
      end
      # elsif current_user.present? && (current_role.include? "contractor_enterprise") && !current_user.admin?
      #   plan = current_user.contractor_plan
      #   if !plan.present?
      #     redirect_to pricing_path(trial_expired: 1), notice: "Please Subscribe to continue."
      #   elsif plan.present?
      #     plan_expired = true
      #     transaction_detail = current_user.transaction_details.where(contractor_plan_id: plan.id).order("id ASC").last
      #     if !plan.price.present? || (transaction_detail.present? && ((transaction_detail.created_at.in_time_zone + plan.time_duration.send(plan.time_duration_postfix)) > DateTime.now.in_time_zone))
      #       plan_expired = false
      #     end
      #     if plan_expired
      #       redirect_to pricing_path(plan_expired: 1), notice: "Your Plan Period has Expired. Please Renew or Upgrade to continue."
      #     end
      #   end
      #end
    end  
  end

  def access_denied(exception)
    redirect_to root_path, alert: exception.message
  end

  def access_denied_admin(exception)
    redirect_to admin_dashboard_path, alert: exception.message
  end

  protected
    def record_not_found
      redirect_to root_path
    end

    def configure_permitted_parameters
      devise_parameter_sanitizer.for(:sign_up) { |u| u.permit(:first_name, :last_name, :full_name, :user_name, :email, :password, :password_confirmation) }
      devise_parameter_sanitizer.for(:sign_in) { |u| u.permit(:login, :user_name, :email, :password, :remember_me) }
      devise_parameter_sanitizer.for(:account_update) { |u| u.permit(:first_name, :last_name, :full_name, :user_name, :email, :password, :password_confirmation, :current_password) }
      # devise_parameter_sanitizer.for(:invite).concat [:first_name, :last_name, :full_name, :user_name]
      devise_parameter_sanitizer.for(:invite) { |u| u.permit(:first_name, :last_name, :full_name, :user_name, :email) }
      devise_parameter_sanitizer.for(:accept_invitation).concat [:first_name, :last_name, :full_name, :user_name]
      devise_parameter_sanitizer.for(:accept_invitation) { |u| u.permit(:first_name, :last_name, :full_name, :user_name, :password, :password_confirmation, :invitation_token) }
    end
end
