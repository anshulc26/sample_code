class ReportsController < ApplicationController
	include ReportsHelper
	include ActionView::Helpers::TextHelper

	## Filters
	before_action :authenticate_user!, :check_report_access, except: [:download_zip_documents, :download_document, :download_site_documents]
	skip_before_action :get_new_user, :get_newsletter, :get_static_page, :recent_post
	before_action :get_report, only: [:show, :destroy]

	def index
		# if user_permission("report_view")
		if (current_role.include?('company') || (current_role.include?('manager') && (current_permissions.include?("Manage Reports")|| current_permissions.include?("Complete Access"))))
			get_reports
		end
	end

	def new
		# if user_permission("report_generate")
		if (current_role.include?('company') || (current_role.include?('manager') && (current_permissions.include?("Manage Reports")|| current_permissions.include?("Complete Access"))))
			@report = current_user.reports.new
			get_all_sites
			if current_role.include?('manager')
				@site_tabs = current_user.company.site_tabs.order("id ASC").pluck(:name).uniq
			else
				@site_tabs = current_user.site_tabs.order("id ASC").pluck(:name).uniq
			end

			@scheduled_reports = current_user.reports.where("reports.email_report_every IS NOT NULL AND reports.email_report_start_from IS NOT NULL AND reports.email_report_last_send_at IS NOT NULL").eager_load(:report_documents).order("reports.id DESC")
			get_extra_params
		end
	end

	def my_report_downlaod
		send_file current_user.reports.last.report_documents.last.document.path
	end

	def download_gip
		#@@filename = "#{@company_name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}.zip"
		filename = params[:filename]+".zip"
		temp_file = Tempfile.new(filename)    
		begin                               
			# Initialize the temp file as a zip file
			report_documents = current_user.reports.last.report_documents
			Zip::OutputStream.open(temp_file) { |zos| }
			# Add files to the zip file
			Zip::File.open(temp_file.path, Zip::File::CREATE) do |zipfile|
				report_documents.each do |report_document|
					zipfile.add(report_document.document.file.file.split("/").last, report_document.document.path)
				end                            
			end				
			# Read the binary data from the file
			zip_data = File.read(temp_file.path)
			# Sending the data to the browser as an attachment
		  send_data(zip_data, type: 'application/zip', filename: filename)
		ensure
		  # Close and delete the temp file
		  temp_file.close
		  temp_file.unlink
		end 
	end

	def create
		# if user_permission("report_generate")
	  if (current_role.include?('company') || (current_role.include?('manager') && (current_permissions.include?("Manage Reports")|| current_permissions.include?("Complete Access"))))
			get_extra_params
			sites = report_params[:sites].to_i rescue ""
			if sites > 0
				params[:report][:site_id] = sites
				params[:report][:sites] = ""
			end
			params[:report][:items] = ["all_items", "compliant_items", "due_soon_items", "non_compliant_items"]
			# if report_params[:report_type] != "let_me_choose_report"
			# 	params[:report][:tabs] = [""]
			# 	if report_params[:report_type] == "compliance_report"
			# 		params[:report][:items] = ["compliant_items"]
			# 	elsif report_params[:report_type] == "full_building_report"
			# 		params[:report][:items] = ["all_items", "compliant_items", "due_soon_items", "non_compliant_items"]
			# 	else
			# 		params[:report][:items] = [""]
			# 	end
			# end
			if report_params[:send_report].present? && (report_params[:send_report].include? "email_report")
				params[:report][:to_email] = report_params[:to_email].reject(&:empty?) if report_params[:to_email].present?
		    params[:report][:cc_email] = report_params[:cc_email].reject(&:empty?) if report_params[:cc_email].present?
			else
				params[:report][:to_email] = []
		    params[:report][:cc_email] = []
			end
			if report_params[:email_report_every].blank? || report_params[:email_report_start_from].blank?
				params[:report][:email_report_every] = ""
		    params[:report][:email_report_start_from] = ""
			end
			@report = current_user.reports.new(report_params)
			scheduled_count = 0
			if report_params[:email_report_every].present? && report_params[:email_report_start_from].present?
				@report.email_report_last_send_at = report_params[:email_report_start_from].to_datetime.in_time_zone.beginning_of_day rescue DateTime.now.in_time_zone.beginning_of_day
				my_scheduled_reports
				scheduled_count = @reports.size
			end
			if (scheduled_count < 3) && @report.report_format.present? && @report.save
				tab_name = @report.tabs
				# if @report.report_type != "let_me_choose_report"
				# 	tab_name = current_user.site_tabs.order("id ASC").pluck(:name).uniq
				# else
				# 	tab_name = @report.tabs
				# end
				if @report.site_id.present?
					@sites = Site.eager_load(:site_tabs).where(id: @report.site_id).where(site_tabs: {name: tab_name})
				else
					@sites = []
					case @report.sites
					when "all_sites"
						get_all_sites(tab_name)
					when "compliant_sites"
						if current_role.include?('manager')
							@sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true, compliant: true).where(site_tabs: {name: tab_name}).order("sites.id DESC")
            else
							@sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true, compliant: true).where(site_tabs: {name: tab_name}).order("sites.id DESC")
						end
					when "due_soon_sites"
						if current_role.include?('manager')
							sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
            else
							sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
						end
						sites.each do |site|
							@sites << site if check_site_due_soon(site)
						end
					when "non_compliant_sites"
						if current_role.include?('manager')
							sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
					  else
							sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
						end
						sites.each do |site|
							@sites << site if !check_site_due_soon(site)
						end
					when "due_non_compliant_sites"
						if current_role.include?('manager')
							@sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
            else
							@sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true, compliant: false).where(site_tabs: {name: tab_name}).order("sites.id DESC")
						end
					else
						get_all_sites(tab_name)
					end
				end

				@sites = @sites.sort_by(&:name)
				@compliant_sites = @sites.select {|site| site.compliant?}
			  @due_compliant_sites = @sites.select {|site| check_site_due_soon(site)}
			  @non_compliant_sites = @sites.select {|site| !check_site_due_soon(site) && !site.compliant}

			  if current_user.present? && (current_role.include? "company")
					@company_name = current_user.company_information.name rescue ""
				elsif current_user.present? && (current_role.include? "manager")
					@company_name = current_company.company_information.name rescue ""
				end

				if @report.report_format.present? && (@report.report_format.include? "pdf")
					pdf_report
				end
        
				if @report.report_format.present? && (@report.report_format.include? "excel")
          excel_report
				end
       
				if @report.send_report.present? && (@report.send_report.include? "email_report")
					if @report.email_report_just_now?
						ReportMailer.email_report(@report).deliver rescue ""
						@saved = true
						respond_to do |format|
					    format.js { render :file => "reports/create.js.erb" }
				    end
					end
				end
				if @report.send_report.present? && (@report.send_report.include? "download_report")
					report_documents = @report.report_documents
					if report_documents.size > 1
					  zip_folder_for_pdf_and_excel(report_documents)	
					elsif report_documents.size == 1
						if params[:report][:email_report_just_now].to_i == 0
							@saved = true
							respond_to do |format|
    						format.js { render :file => "reports/scheduled_popup.js.erb" }
							end
						else
							#send_file report_documents.last.document.path
							respond_to do |format| 
								format.js {render js: 'window.location = "/reports/my_report_downlaod";'}
								#format.js {render js: 'window.location = "/reports/download_gip";'}
							end
						end 
					else
						redirect_to root_path(tab: @tab, page: @page, order: @order, search: @search, from_date: @from_date, to_date: @to_date, site_type: @site_type)
					end
				else
					#redirect_to root_path(tab: @tab, page: @page, order: @order, search: @search, from_date: @from_date, to_date: @to_date, site_type: @site_type)
				end
				@saved = true
			else
				@saved = false
				respond_to do |format|
					format.js { render :file => "reports/scheduled_popup.js.erb" }
				end
			end
		end
	end

	def destroy
		# if user_permission("report_delete")
		if (current_role.include?('company') || (current_role.include?('manager') && (current_permissions.include?("Manage Reports")|| current_permissions.include?("Complete Access"))))
			@report_id = @report.id
			@destroy = @report.destroy
		end
	end

	def my_scheduled_reports
		# if user_permission("report_view")
		if (current_role.include?('company') || (current_role.include?('manager') && (current_permissions.include?("Manage Reports")|| current_permissions.include?("Complete Access"))))
			if current_role.include? "manager"
				@reports = Report.where("(reports.user_id = ? OR reports.user_id = ?) AND reports.email_report_every IS NOT NULL AND reports.email_report_start_from IS NOT NULL AND reports.email_report_last_send_at IS NOT NULL", current_user.id, current_company.id).eager_load(:report_documents).order("reports.id DESC")
			else
				@reports = current_user.reports.where("reports.email_report_every IS NOT NULL AND reports.email_report_start_from IS NOT NULL AND reports.email_report_last_send_at IS NOT NULL").eager_load(:report_documents).order("reports.id DESC")
			end
		end
	end

	def get_reports
		if current_role.include? "manager"
			@reports = Report.where("reports.user_id = ? OR reports.user_id = ?", current_user.id, current_company.id).eager_load(:report_documents).order("reports.id DESC").first(10)
		else
			@reports = current_user.reports.eager_load(:report_documents).order("reports.id DESC").first(10)
		end
	end

	def download_site_documents
		@site = Site.find(params[:id])
		@report = Report.find(params[:report_id])
		if @report.document_expires==2
			@time=@report.created_at.to_time+2.minutes
		else
			@time=@report.created_at + @report.document_expires.days
		end
		if @report.present? && ((@time >= DateTime.now) || (@report.document_expires == 0))
			site_item_documents = []
			item_documents = []
			site_tabs = @site.site_tabs.select{|site_tab| @report.tabs.include?(site_tab.name)}
			site_tabs.each do |site_tab|
				site_tab.site_items.each do |site_item|
					item_documents << site_item.site_item_documents if site_item.site_item_documents.present?
				end
			end
			item_documents = item_documents.flatten
			filename = "#{@site.name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}.zip"
			temp_file = Tempfile.new(filename)
			begin
				# Initialize the temp file as a zip file
				Zip::OutputStream.open(temp_file) { |zos| }
				# Add files to the zip file
				Zip::File.open(temp_file.path, Zip::File::CREATE) do |zipfile|
	        if @report.documents.include? "all_current_documents"
	          site_item_documents << item_documents.select{|d| d.current? && d.approve?}
	        end
	        if @report.documents.include? "archived_documents"
	          site_item_documents << item_documents.select{|d| d.archive?}
	        end
					site_item_documents.flatten.each do |site_item_document|
						zipfile.add(site_item_document.file.file.file.split("/").last, site_item_document.file.path) if site_item_document.file.present? && site_item_document.file.file.exists?
					end
				end
				# Read the binary data from the file
				zip_data = File.read(temp_file.path)
				# Sending the data to the browser as an attachment
			  send_data(zip_data, type: 'application/zip', filename: filename)
			ensure
			  # Close and delete the temp file
			  temp_file.close
			  temp_file.unlink
			end
		else
			render layout: false
		end
	end

	def download_zip_documents
		@site_item = SiteItem.find(params[:id])
		@report = Report.find(params[:report_id])
		if @report.document_expires==2
			@time=@report.created_at.to_time+2.minutes
		else
			@time=@report.created_at + @report.document_expires.days
		end
		if @report.present? && ((@time >= DateTime.now) || (@report.document_expires == 0))
			site_item_documents = []
			item_documents = @site_item.site_item_documents
			filename = "#{@site_item.title}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}.zip"
			temp_file = Tempfile.new(filename)
			begin
				# Initialize the temp file as a zip file
				Zip::OutputStream.open(temp_file) { |zos| }
				# Add files to the zip file
				Zip::File.open(temp_file.path, Zip::File::CREATE) do |zipfile|
	        if @report.documents.include? "all_current_documents"
	          site_item_documents << item_documents.select{|d| d.current? && d.approve?}
	        end
	        if @report.documents.include? "archived_documents"
	          site_item_documents << item_documents.select{|d| d.archive?}
	        end
					site_item_documents.flatten.each do |site_item_document|
						zipfile.add(site_item_document.file.file.file.split("/").last, site_item_document.file.path) if site_item_document.file.present? && site_item_document.file.file.exists?
					end
				end
				# Read the binary data from the file
				zip_data = File.read(temp_file.path)
				# Sending the data to the browser as an attachment
			  send_data(zip_data, type: 'application/zip', filename: filename)
			ensure
			  # Close and delete the temp file
			  temp_file.close
			  temp_file.unlink
			end
		else
			render layout: false
		end
	end

	def download_document
		@report = Report.find(params[:report_id])
		if @report.document_expires==2
		  @time=@report.created_at.to_time+2.minutes
		else
			@time=@report.created_at + @report.document_expires.days
		end
		if @report.present? && ((@time >= DateTime.now) || (@report.document_expires == 0))
			doc = SiteItemDocument.find(params[:id])
			filename = File.join("#{Rails.root}/public", "#{doc.file.url}")
      filename = URI.decode(filename)
			send_file(filename, type: doc.file.content_type, filename: doc.file_identifier.split("_").last,:disposition => 'attachment') if doc.file.file.exists?
		else
			render layout: false
		end
	end

	private
		def check_report_access
			unless (remaining_days > 0) || (current_plan.present? && current_plan.reports.join(",").present?) || current_user.admin?
				redirect_to root_path
			end
		end

		def get_report
			# if current_role.include?('manager')
			@report = current_user.reports.find(params[:id]) rescue ""
      unless @report.present?
        redirect_to root_path
      end
		end

		def get_all_sites(tab_name=nil)
			if tab_name.present?
				if current_role.include?('manager')
					@sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true).where(site_tabs: {name: tab_name}).order("sites.id DESC")
        else
					@sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true).where(site_tabs: {name: tab_name}).order("sites.id DESC")
				end
			else
				if current_role.include?('manager')
					@sites = Site.eager_load(:site_tabs).where(user_id: current_user.company.id, active: true).order("sites.id DESC")
        else
					@sites = Site.eager_load(:site_tabs).where(user_id: current_user.id, active: true).order("sites.id DESC")
				end
			end
		end

		def get_extra_params
      @tab = params[:tab].present? ? params[:tab] : nil
      @page = params[:page].present? ? params[:page] : "1"
      @order = params[:order].present? ? params[:order] : nil
      @search = params[:search].present? ? params[:search] : nil
      @from_date = params[:from_date].present? ? params[:from_date] : nil
      @to_date = params[:to_date].present? ? params[:to_date] : nil
      @site_type = params[:site_type].present? ? params[:site_type] : nil
    end

		def report_params
			params.require(:report).permit(:site_id, :sites, :report_type, :report_template, :document_expires, :lock_document, :email_report_just_now, :email_report_every, :email_report_start_from, {tabs: [], items: [], documents: [], report_format: [], send_report: [], to_email: [], cc_email: [], to_schedule: [], reports: []})
		end
    
    def excel_report
			if @report.report_format.present? && (@report.report_format.include? "excel")
				total_sites = @sites.size
				sites_per_file = 200
				total_xls_files = (total_sites.to_f / sites_per_file).ceil
				if (total_xls_files > 1 && @report.report_template == "detailed_site_tab_report")
					(1..total_xls_files).each do |i|
						@sites_new = @sites.drop((i-1)*sites_per_file).first(sites_per_file)
						@compliant_sites_new = @sites_new.select {|site| site.compliant_status == "compliant"}
						@due_compliant_sites_new = @sites_new.select {|site| site.compliant_status == "due_soon"}
						@non_compliant_sites_new = @sites_new.select {|site| site.compliant_status == "overdue"}
						xlsx_package = Axlsx::Package.new
						xlsx_package.use_autowidth = false
						wb = xlsx_package.workbook
						wb.styles do |style|
						  wb.add_worksheet(name: "Sites") do |sheet|
						    report_xls(wb, sheet, @report, @sites_new, @compliant_sites_new, @due_compliant_sites_new, @non_compliant_sites_new)
						  end
						end
						if @report.site_id.present?
							if @report.tabs.include?('All Tabs')
								name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+"All_tabs"
							else
								name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
							end
						else
							if @report.tabs.include?('All Tabs')
								name=@report.sites+"|"+@report.report_template+"|"+"All_tabs"
							else
								name=@report.sites+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
							end
						end
						name = name.titleize.gsub(" ","_")
						sites_from = sites_per_file*(i-1)+1
						sites_to = (i==total_xls_files) ? total_sites : (sites_per_file*(i-1)+sites_per_file)
						sites_range = "#{sites_from}-#{sites_to}"
						filename = "#{name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}_Sites-#{sites_range}.xlsx"
						dir = File.dirname("#{Rails.root}/public/uploads/reports/#{filename}")
		  			FileUtils.mkdir_p(dir) unless File.directory?(dir)
						File.open("#{Rails.root}/public/uploads/reports/#{filename}", 'wb') do |file|
						  file.write(xlsx_package.to_stream.read)
						end
						@report.report_documents.create(document: Pathname.new("#{Rails.root}/public/uploads/reports/#{filename}").open)
						File.delete("#{Rails.root}/public/uploads/reports/#{filename}")
					end
				else
					xlsx_package = Axlsx::Package.new
					xlsx_package.use_autowidth = false
					wb = xlsx_package.workbook
					wb.styles do |style|
					  wb.add_worksheet(name: "Sites") do |sheet|
					    report_xls(wb, sheet, @report, @sites, @compliant_sites, @due_compliant_sites, @non_compliant_sites)
					  end
					end
					if @report.site_id.present?
						if @report.tabs.include?('All Tabs')
							name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+"All_tabs"
						else
							name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
						end
					else
						if @report.tabs.include?('All Tabs')
							name=@report.sites+"|"+@report.report_template+"|"+"All_tabs"
						else
							name=@report.sites+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
						end
					end
					name = name.titleize.gsub(" ","_")
					filename = "#{name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}.xlsx"
					dir = File.dirname("#{Rails.root}/public/uploads/reports/#{filename}")
	  			FileUtils.mkdir_p(dir) unless File.directory?(dir)
					File.open("#{Rails.root}/public/uploads/reports/#{filename}", 'wb') do |file|
					  file.write(xlsx_package.to_stream.read)
					end
					@report.report_documents.create(document: Pathname.new("#{Rails.root}/public/uploads/reports/#{filename}").open)
					File.delete("#{Rails.root}/public/uploads/reports/#{filename}")
				end
	    end
	  end		

	  def pdf_report
	  	if @report.report_template == "general_site_report"
				template = "reports/general_site.html.erb"
				footer = "shared/pdf_footer.html.erb"
			elsif @report.report_template == "general_site_tab_report"
				template = "reports/general_site_and_tab.html.erb"
				footer = "shared/pdf_footer.html.erb"
			elsif @report.report_template == "detailed_site_tab_report"
				template = "reports/detailed_site_and_tab.html.erb"
				footer = nil
			else
				template = "reports/general_site.html.erb"
				footer = "shared/pdf_footer.html.erb"
			end
			if @report.site_id.present?
				if @report.tabs.include?('All Tabs')
					name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+"All_tabs"
				else
					name=Site.find(@report.site_id).name+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
				end
			else
				if @report.tabs.include?('All Tabs')
					name=@report.sites+"|"+@report.report_template+"|"+"All_tabs"
				else
					name=@report.sites+"|"+@report.report_template+"|"+ @report.tabs.join(',').truncate(15)
				end
			end
			name = name.titleize.gsub(" ","_")
			filename = "#{name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}.pdf"
	    pdf = render_to_string  pdf: "project_report.pdf",
	      layout: 'pdf_mode.html.erb',
	      show_as_html: false,
	      encoding: "UTF-8",
	      disable_internal_links: false,
	      disable_external_links: false,
	      template: template,
	      footer: { html: { template: footer } } 

			dir = File.dirname("#{Rails.root}/public/uploads/reports/#{filename}")
			FileUtils.mkdir_p(dir) unless File.directory?(dir)

      save_path = Rails.root.join(dir, filename)
      File.open(save_path, 'wb') do |file|
        file << pdf
      end
			@report.report_documents.create(document: Pathname.new("#{Rails.root}/public/uploads/reports/#{filename}").open)
			File.delete("#{Rails.root}/public/uploads/reports/#{filename}")
	  end		

	  def zip_folder_for_pdf_and_excel(report_documents)
		  filename = "#{@company_name}-#{DateTime.now.in_time_zone.strftime("%d-%b-%y-%H:%M:%S")}"
	  	respond_to do |format| 
				format.js {render js: "window.location = '/reports/download_gip?filename=#{filename}';"}
			end
	  end
end
