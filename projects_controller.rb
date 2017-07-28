class ProjectsController < ApplicationController
  include ActionView::Helpers::NumberHelper
  ## Filters
  before_action :authenticate_user!
  before_action :set_project, only: [:show, :edit, :update, :destroy_show, :destroy, :building_entry, :building, :building_data_entry, :save_building_data_entry, :project_building_services, :update_building_services, :project_building_system, :update_building_system, :project_building_type, :update_building_type, :disclaimer, :update_disclaimer, :report, :report_export, :show_generate_report, :show_download_report, :get_total_area_building, :check_data_entries, :check_system_architecture]
  before_action :set_building, only: [:building_data_entry, :save_building_data_entry, :check_system_architecture]
  before_action :set_page, only: [:index, :projects_pending, :destroy, :destroy_show]
  before_action :check_credits, only: [:new, :create]
  before_action :set_first_param, only: [:new, :create, :edit, :update, :destroy, :building, :building_entry, :project_building_services, :update_building_services, :project_building_system, :update_building_system, :project_building_type, :update_building_type, :report, :check_data_entries]
  before_action :set_facility_option, only: [:building, :building_entry, :new, :create, :edit, :update, :destroy, :project_building_services, :update_building_services, :project_building_system, :update_building_system, :project_building_type, :update_building_type, :disclaimer, :report, :check_data_entries]
  before_action :check_project_finished, only: [:edit, :building_entry, :project_building_services, :project_building_system, :project_building_type]
  skip_before_action :set_static_page, only: [:destroy_show, :save_building_data_entry, :update_disclaimer, :show_generate_report, :get_floor_plan_message, :get_total_area_building, :check_system_architecture]

  def index
    @completed = true
    @projects = Project.completed_projects(current_user.id, @page)
  end

  def projects_pending
    @completed = false
    @projects = Project.pending_projects(current_user.id, @page)
  end

  def new
    @project = current_user.projects.new
    @project.user_name = current_user.user_name
  end

  def edit
  end

  def create
    @saved = false
    @authorized = true
    params[:project][:step_completed] = 1
    facility_option = params[:project][:facility_option]
    if facility_option.present? && (facility_option == "Building")
      if check_subscription(facility_option)
        @project = current_user.projects.new(project_params)
        if @project.save
          @facility = @project.facility_option rescue ""
          @saved = true
          @building = @project.build_building
        end
      else
        @authorized = false
      end
    elsif facility_option.present? && (facility_option == "Tunnel")
      if check_subscription(facility_option)
        @project = current_user.tunnel_projects.new(project_params)
        if @project.save
          @facility = @project.facility_option rescue ""
          @saved = true
          @tunnel = @project.build_tunnel
        end
      else
        @authorized = false
      end
    end
    if @saved && !current_user.admin?
      current_user.update_column(:credits, current_user.credits - 1)
    end
  end

  def update
    @saved = @project.update(project_params)
    if @saved
      if @project.building.present?
        @building = @project.building
      else
        @building = @project.build_building
      end
    end
  end

  def destroy_show
    @discard = false
    if params[:discard].present?
      @discard = true
    end
  end

  def destroy
    @discard = false
    if params[:discard].present? && (params[:discard] == "true")
      @discard = true
    end
    @completed = true
    if @project.present?
      unless @project.report?
        @completed = false
      end
      @project.really_destroy!
    end
    if @completed
      @projects = Project.completed_projects(current_user.id, @page)
      set_page
      unless @projects.present?
        if @page.present? && (@page.to_i > 1)
          @page = (@page.to_i - 1).to_s
        else
          @page = 1
        end
        @projects = Project.completed_projects(current_user.id, @page)
      end
    else
      @projects = Project.pending_projects(current_user.id, @page)
      set_page
      unless @projects.present?
        if @page.present? && (@page.to_i > 1)
          @page = (@page.to_i - 1).to_s
        else
          @page = 1
        end
        @projects = Project.pending_projects(current_user.id, @page)
      end
    end
  end

  def building_entry
    if @project.building.present?
      @building = @project.building
    else
      @building = @project.build_building
    end
  end

  def building
    @saved = false
    @building = @project.building
    if @building.present?
      if @building.update(building_params)
        @saved = true
      end
    else
      @building = @project.build_building(building_params)
      if @building.save
        @saved = true
      end
    end
    if @saved && !@project.report?
      @project.update_column(:step_completed, 2)
    end
  end

  def building_data_entry
    building_last_data_entry = @building.building_data_entries.order("id ASC").last
    @building_data_entry = @building.building_data_entries.new
    @building_data_entry.building_number = 1
    @building_data_entry.floor_number = 1
    if building_last_data_entry.present? && building_last_data_entry.floor_number.present?
      if building_last_data_entry.building_number < @building.number_of_buildings && building_last_data_entry.floor_number < building_last_data_entry.number_of_floors
        @building_data_entry.building_name = building_last_data_entry.building_name
        @building_data_entry.building_number = building_last_data_entry.building_number
        @building_data_entry.number_of_floors = building_last_data_entry.number_of_floors
        @building_data_entry.floor_number = building_last_data_entry.floor_number + 1
      else
        @building_data_entry.building_number = building_last_data_entry.building_number + 1 if building_last_data_entry.building_number < @building.number_of_buildings
      end
    else
      @building_data_entry.building_number = building_last_data_entry.building_number + 1 if building_last_data_entry.present? && building_last_data_entry.building_number < @building.number_of_buildings
    end
  end

  def save_building_data_entry
    @no_floor_area = true
    if building_data_entry_params[:floor_number].present?
      @no_floor_area = false
      building_data_entry = @building.building_data_entries.where(building_number: building_data_entry_params[:building_number], floor_number: building_data_entry_params[:floor_number]).last
      if building_data_entry.present?
        building_data_entry.destroy
      end
      params[:building_data_entry][:building_slope] = BuildingEnvironment.find_by_id(building_data_entry_params[:building_environment_id]).try(:building_indoor_factor)
      @building_data_entry = @building.building_data_entries.new(building_data_entry_params)
      @saved = @building_data_entry.save

      building_data_entries = @building.building_data_entries.where(building_number: @building_data_entry.building_number)
      total_area = building_data_entries.sum(:area_this_floor)
      building_data_entries.each do |building_data_entry|
        building_data_entry.update_column(:total_area_building, total_area)
      end
    else
      building_data_entry = @building.building_data_entries.where(building_number: building_data_entry_params[:building_number]).last
      if building_data_entry.present?
        building_data_entry.destroy
      end
      params[:building_data_entry][:building_slope] = BuildingEnvironment.find_by_id(building_data_entry_params[:building_environment_id]).try(:building_indoor_factor)
      @building_data_entry = @building.building_data_entries.new(building_data_entry_params)
      @saved = @building_data_entry.save
    end
  end

  def project_building_services
  end

  def update_building_services
    if params[:autoselect_channel].present?
      product_frequency_channel_id = ProductFrequencyChannel.where(default_selected: true).last.try(:id)
      params[:project][:product_frequency_channel_id] = product_frequency_channel_id
    end
    unless @project.report?
      params[:project][:step_completed] = 3
    end
    @saved = @project.update(building_services_params)
    if @saved
      #### Update frequency DB 7 Building Data Entry
      building_data_entries = @project.building.building_data_entries
      building_data_entries.each do |building_data_entry|
        frequency = @project.highest_frequency_band / 1000.0
        building_data_entry.update(frequency: frequency)
      end
      
      @system_feed_methods = SystemFeedMethod.order("id ASC")
      @system_architectures = SystemArchitecture.order("id ASC")
    end
  end

  def project_building_system
    @system_feed_methods = SystemFeedMethod.order("id ASC")
    @system_architectures = SystemArchitecture.order("id ASC")
  end

  def update_building_system
    if params[:project][:system_feed_method].present? && (params[:project][:system_feed_method] == "Auto Select")
      params[:project][:system_feed_method] = SystemFeedMethod.where(default_selected: true).last.try(:feed_method)
    end
    if params[:project][:system_architecture].present? && (params[:project][:system_architecture] == "Auto Select")
      square_foot = SquareFootageSize.last.square_foot

      total_area_building = 0.0
      building_data_entries = @project.building.building_data_entries
      building_numbers = building_data_entries.pluck(:building_number).uniq.sort
      building_numbers.each do |bn|
        building_entry = building_data_entries.where(building_number: bn).order("id ASC").last
        total_area_building += building_entry.total_area_building
      end
      if total_area_building < square_foot
        params[:project][:system_architecture] = "Coax"
      elsif total_area_building >= square_foot
        params[:project][:system_architecture] = "Fiber and Coax"
      end
    end
    if params[:autoselect_rssi].present?
      expected_rssi_at_mobile = RssiThresholdLevelBenchmark.where(default_selected: true).last.try(:threshold_level)
      params[:project][:expected_rssi_at_mobile] = expected_rssi_at_mobile
    end
    unless @project.report?
      params[:project][:step_completed] = 4
    end
    @saved = @project.update(building_system_params)
  end

  def project_building_type
  end

  def update_building_type
    if params[:autoselect_technology].present?
      technology_type = TechnologyType.where(default_selected: true).last
      params[:project][:technology_type] = technology_type.try(:technology)
      params[:project][:papr] = technology_type.try(:papr)
    elsif params[:project][:technology_type].present?
      technology_type = TechnologyType.where(technology: params[:project][:technology_type]).last
      params[:project][:papr] = technology_type.try(:papr)
    end
    if params[:project][:communication_type].present? && (params[:project][:communication_type] == "Auto Select")
      params[:project][:communication_type] = CommunicationType.where(default_selected: true).last.try(:communication)
    end
    unless @project.report?
      params[:project][:step_completed] = 5
      params[:project][:report] = true
    end
    @saved = @project.update(building_type_params)
  end

  def disclaimer
    if @project.disclaimer_acknowledgement?
      redirect_to report_project_path(@project, facility: @facility)
    end
  end

  def update_disclaimer
    @saved = false
    if params[:disclaimer_acknowledge].present? && (params[:disclaimer_acknowledge] == "true")
      @saved = @project.update_column(:disclaimer_acknowledgement, true)
    end
  end

  def report
    unless @project.disclaimer_acknowledgement?
      redirect_to disclaimer_project_path(@project, facility: @facility)
    end
    @building_plan = current_user.building_plan
    if @building_plan.present?
      building_plan_name = @building_plan.name.split(" ").first
      @timer_setting = TimerSetting.where(plan_name: building_plan_name).last
    else
      @timer_setting = TimerSetting.order("id ASC").first
    end
  end

  def show_generate_report
    unless @project.visited_report?
      @project.update_column(:visited_report, true)
    end
  end

  def show_download_report
  end

  def report_export
    @building_plan = current_user.building_plan
    @images_path = "#{request.protocol}#{request.host_with_port}/assets"
    pdf = render_to_string  pdf: "project_report.pdf",
      layout: 'pdf_mode.html.erb',
      show_as_html: false,
      encoding: "UTF-8",
      template: 'projects/report_export.html.erb',
      footer: { html: { template: 'shared/pdf_footer.html.erb' } }
    send_data pdf, filename: "project_report#{@project.id}.pdf", type: "application/pdf", disposition: "attachment"
  end

  def get_floor_plan_message
    @message = ""
    if params[:floor_plan].present?
      @message = HaveFloorPlan.where(operator: params[:floor_plan]).first.try(:operand)
    end
  end

  def get_total_area_building
    @total = ""
    building_number = params[:building_number]
    if building_number.present?
      building_data_entries = @project.building.building_data_entries.where(building_number: building_number)
      if building_data_entries.present?
        @total = building_data_entries.sum(:area_this_floor)
      end
    end
  end

  def check_data_entries
  end

  def check_system_architecture
    @selected = params[:system_architecture]
    if @selected.present?
      @system_architecture = ""
      @buildings = 0
      @total_buildings = 0
      total_area_building = 0.0
      square_foot = SquareFootageSize.last.square_foot
      building_data_entries = @building.building_data_entries

      if building_data_entries.present?
        @total_buildings = building_data_entries.pluck(:building_number).uniq.sort
        @total_buildings.each do |bn|
          building_entry = building_data_entries.where(building_number: bn).order("id ASC").last
          total_area_building += building_entry.total_area_building
          if @selected == "Fiber and Coax"
            if building_entry.total_area_building < square_foot
              @buildings += 1
              @system_architecture = "Coax"
            end
          elsif @selected == "Coax"
            if building_entry.total_area_building >= square_foot
              @buildings += 1
              @system_architecture = "Fiber and Coax"
            end
          end
        end
      end
    end
  end

  private
    def load_projects
      @completed_projects = Project.completed_projects(current_user.id, params[:page])
      @pending_projects = Project.pending_projects(current_user.id, params[:page])
    end

    def set_project
      @project = Project.get_project(params[:id], current_user.id)
      unless @project.present?
        redirect_to root_path
      end
    end

    def check_project_finished
      if @project.building_type?
        redirect_to report_project_path(@project, facility: @facility)
      end      
    end

    def set_building
      @building = @project.building
    end

    def set_first_param
      @first = 1 if params[:first].present?      
    end

    def set_facility_option
      @facility = params[:facility] rescue ""
    end

    def set_page
      @page = params[:page].present? ? params[:page] : "1"
    end

    def project_params
      params.require(:project).permit(:user_name, :project_name, :company, :name, :facility_option, :step_completed)
    end

    def building_params
      params.require(:building).permit(:number_of_buildings, :have_floorplan)
    end

    def building_data_entry_params
      params.require(:building_data_entry).permit(:building_name, :building_number, :floor_number, :number_of_floors, :area_this_floor, :total_area_building, :building_slope, :building_environment_id)
    end

    def building_services_params
      params.require(:project).permit(:number_of_services, :highest_frequency_band, :product_frequency_channel_id, :step_completed)
    end

    def building_system_params
      params.require(:project).permit(:system_feed_method, :system_architecture, :expected_rssi_at_mobile, :marketing_vendor_name, :marketing_id, :step_completed, :report)
    end

    def building_type_params
      params.require(:project).permit(:technology_type, :papr, :communication_type, :step_completed, :report)
    end
end
