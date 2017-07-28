require "#{Rails.root}/app/controllers/application_controller"

namespace :sites do
	desc "Check Site Compliance"
	task compliance: :environment do
    begin
			sites = Site.all.eager_load(site_tabs: {site_items: :site_item_questions}).where(active: true)
			sites.each do |site|
				user =  site.user
				site_items = site.site_tabs.inject([]) {|site_items, site_tab| site_items << site_tab.site_items}.flatten
		    site_items.each do |site_item|
		    	## Sent item overdue mail
					if site_item.due_date.present? && Date.today.in_time_zone.to_date >= site_item.due_date.in_time_zone.to_date
		        if site_item.compliant_status=="due_soon" && !site_item.due_expired_mail?
		          site_item.update(compliant: false, compliant_status: "overdue", due_expired_mail: true)
		          begin
		            notification = user.notifications.create(body: "Site '#{site.name}', Item '#{site_item.title} - '#{site_item.frequency}' Due Date #{site.annual_compliance_due.in_time_zone.strftime("%d/%m/%Y")}' has expired. Please compliance the site as soon as possible.")
		            publish_notification(notification, user)
		            SiteMailer.site_item_due_expired(site, site_item, user).deliver_now
		          rescue => e
		            Rails.logger.info "SiteMailer - site_item_due_expired: #{e}"
		          end
		        end
		      end

		      ## Use for update site_item.compliant_status and due_date (use only for precaution)
		      ##--Start--##
		    	if site_item.present?
			    	site_item_questions = site_item.site_item_questions.select{|site_item_question| site_item_question.required_for_compliant?}
			      case site_item.frequency
			      when "Daily"
			        next_due = 1.day
			      when "Weekly"
			        next_due = 1.week
			      when "Monthly"
			        next_due = 1.month
			      when "Quarterly"
			        next_due = 3.month
			      when "Bi-Annually"
			        next_due = 6.month
			      when "Annually"
			        next_due = 1.year
			      else
			        next_due = 1.month
			      end

			      due_date = site_item.due_date.in_time_zone rescue nil
			      if due_date.present?
			        if site_item.compliant?
			          if ((DateTime.now.in_time_zone >= ((site_item.due_date.in_time_zone - next_due) - site_item.due_soon.send(site_item.due_soon_duration))) && (DateTime.now.in_time_zone < (site_item.due_date.in_time_zone - next_due)))
			            due_date = site_item.due_date.in_time_zone - next_due
			          else
			            due_date = site_item.due_date.in_time_zone
			          end
			        else
			          if (site_item_questions.size >= 0) && (site_item_questions.select{|site_item_question| site_item_question.required_for_compliant?}.size == (site_item_questions.select{|site_item_question| site_item_question.compliant?}.size))
			            if ((DateTime.now.in_time_zone >= (site_item.due_date.in_time_zone - site_item.due_soon.send(site_item.due_soon_duration))))
			              due_date = site_item.due_date.in_time_zone + next_due
			            else
			              due_date = site_item.due_date.in_time_zone
			            end
			          else
			            due_date = site_item.due_date.in_time_zone
			          end
			        end
			      end

			      if (site_item_questions.size >= 0) && (site_item_questions.select{|site_item_question| site_item_question.required_for_compliant?}.size == (site_item_questions.select{|site_item_question| site_item_question.compliant?}.size))
			        if !site_item.compliant?
			        	site_item.update(compliant: true, compliant_status: "compliant", due_expired_mail: false, due_warning_mail: false, due_date: due_date)
			        	site_item.user_tokens.destroy_all
			        end
			      elsif (DateTime.now.in_time_zone >= (due_date - site_item.due_soon.send(site_item.due_soon_duration))) && (DateTime.now.in_time_zone < due_date)
			        site_item.update(compliant: false, compliant_status: "due_soon", due_date: due_date) unless site_item.compliant_status=="due_soon"
			      elsif (DateTime.now.in_time_zone > due_date) || (DateTime.now.in_time_zone < (due_date - site_item.due_soon.send(site_item.due_soon_duration)))
			        site_item.update(compliant: false, compliant_status: "overdue", due_date: due_date) unless site_item.compliant_status=="overdue"
			      end
			    end
			    ##--End--##

		      ## Sent item due soon mail
		      if site_item.due_date.present? && ((DateTime.now.in_time_zone >= (site_item.due_date.in_time_zone - site_item.due_soon.send(site_item.due_soon_duration))) && (DateTime.now.in_time_zone < site_item.due_date.in_time_zone)) && !site_item.due_warning_mail?
		        site_item.update(compliant: false, due_warning_mail: true, compliant_status: "due_soon")
		        site_item_questions = site_item.site_item_questions.update_all(compliant: false) rescue []
		        site_item_documents = site_item.site_item_documents.where(current: true, approve: true) rescue []
		        if site_item_documents.present? && site_item_documents[0].try(:automatic_archive)
		          site_item_documents.update_all(current: false, approve: false, archive: true)
		        end
		        begin
		          notification = user.notifications.create(body: "Site '#{site.name}', Item '#{site_item.title} - '#{site_item.frequency}' Due Date #{site.annual_compliance_due.in_time_zone.strftime("%d/%m/%Y")}' is soon. Please compliance the site as soon as possible.")
		          publish_notification(notification, user)
		          SiteMailer.site_item_due_warning(site, site_item, user).deliver_now
		        rescue => e
		          Rails.logger.info "SiteMailer - site_item_due_warning: #{e}"
		        end
		      end
		    end

	      ## Sent site overdue mail
	      if Date.today.in_time_zone.to_date > site.annual_compliance_due.in_time_zone.to_date
	        if site.compliant?
	          site.update(annual_compliance_due: site.annual_compliance_due.in_time_zone + 1.year)
	        elsif !site.due_expired_mail?
	        	site.site_item_questions.update_all(compliant: false)
	        	site.site_items.update_all(compliant: false, compliant_status: "overdue")
	        	site.site_tabs.update_all(compliant: false, compliant_status: "overdue")
	          site.update(compliant: false, due_expired_mail: true, compliant_status: "overdue")
	          begin
	            notification = user.notifications.create(body: "Site '#{site.name}' Due Date #{site.annual_compliance_due.in_time_zone.strftime("%d/%m/%Y")} has expired. Please compliance the site as soon as possible.")
	            publish_notification(notification, user)
	            SiteMailer.site_due_expired(site, user).deliver_now
	          rescue => e
	            Rails.logger.info "SiteMailer - site_due_expired: #{e}"
	          end
	        end
	      end

	      ## Sent item due soon mail
	      if (site.compliant_status=="due_soon") && !site.due_warning_mail?
	        site.update(compliant: false, due_warning_mail: true, compliant_status: "due_soon")
	        begin
	          notification = user.notifications.create(body: "Site '#{site.name}' Due Date #{site.annual_compliance_due.in_time_zone.strftime("%d/%m/%Y")} is soon. Please compliance the site as soon as possible.")
	          publish_notification(notification, user)
	          SiteMailer.site_due_warning(site, user).deliver_now
	        rescue => e
	          Rails.logger.info "SiteMailer - site_due_warning: #{e}"
	        end
	      end

	      if Date.today >= site.shut_down
	        min_tokens = (site_items.size < minimum_tokens ? minimum_tokens : site_items.size)
	        total_tokens_used = site_items.map{|s| s.total_tokens_used}.sum
	        if total_tokens_used >= min_tokens
	          site.update(shut_down: site.shut_down + 1.year)
	          site_items.update_all(total_tokens_used: 0)
	        end
	      end
	      
	      ## Use for update site.compliant_status (use only for precaution)
				site_tabs = site.site_tabs
	      site_tabs.each do |site_tab|
	        site_tabs = site.site_tabs
					if site_tabs.present? && (site_tabs.select{|site_tab| !site_tab.compliant?}.size > 0)
			      if (site_tabs.select{|site_tab| site_tab.compliant_status == "overdue"}.size > 0)
			      	site.update(compliant: false, compliant_status: "overdue") unless site.compliant_status=="overdue"
						elsif (site_tabs.select{|site_tab| site_tab.compliant_status == "due_soon"}.size > 0)
			      	site.update(compliant: false, compliant_status: "due_soon") unless site.compliant_status=="due_soon"
						end
			    else
			      site.update(compliant: true, compliant_status: "compliant", due_expired_mail: false, due_warning_mail: false) unless site.compliant_status=="compliant"
			    end
	      end 
			end

			## Use for Destroy expired SiteItemInvitation
			site_item_invitations = SiteItemInvitation.all
      site_item_invitations.each do |site_item_invitation|
        if site_item_invitation.access_expires.present? && (site_item_invitation.access_expires != "never")
          destroy = false
          if site_item_invitation.access_expires == "select_date"
            destroy = true unless site_item_invitation.access_expires_date.present? && (site_item_invitation.access_expires_date.in_time_zone >= DateTime.now.in_time_zone)
          else
            access_expires = site_item_invitation.access_expires.split(".")
            if access_expires.present? && (access_expires.size == 2)
              access_date = site_item_invitation.created_at.in_time_zone + access_expires.first.to_i.send(access_expires.last) rescue site_item_invitation.created_at.in_time_zone
              destroy = true unless access_date >= DateTime.now.in_time_zone
            end
          end
          site_item_invitation.destroy if destroy
        end
      end

      ## Use for update user's UserSitesStatusCount model to calculate sites statuswise (use only for precaution)
			@users = User.with_role("company")
			@users.each do |user|
			  @compliant = 0
			  @due_soon = 0
			  @overdue = 0
			  sites = user.sites.where(active: true)
			  sites.each do |site|
			    case site.compliant_status
			    when "compliant"
			      @compliant += 1
			    when "overdue"
			      @overdue += 1
			    when "due_soon"
			      @due_soon += 1
			    end
			  end
			  @total_sites = sites.size
			  user.build_user_sites_status_count(compliant_size: @compliant, overdue_size: @overdue, due_soon_size: @due_soon, total_sites_size: @total_sites).save
			end
	  rescue => e
			Rails.logger.info "Check Site Compliance: #{e}"
		end
	end
end

# 5 0 * * * /bin/bash -l -c 'cd {app_path} && RAILS_ENV=production bundle exec rake sites:compliance --silent >> log/cron_log.log 2>&1'
