class Project < ActiveRecord::Base
	## Soft Delete
	acts_as_paranoid

	## Friendly ID
	extend FriendlyId
	friendly_id :project_name

	## Relations
	belongs_to :user
	belongs_to :product_frequency_channel
	belongs_to :marketing
	has_one :building, dependent: :destroy

	## Validations
	validates :user_id, presence: true, numericality: { only_integer: true }
	validates :user_name, :project_name, :company, :facility_option, presence: true
	validates :number_of_services, :highest_frequency_band, :product_frequency_channel_id, :marketing_id, numericality: { only_integer: true }, allow_nil: true

	## Callbacks
	after_update :save_building_data_entries_info, :send_admin_email

	## Show Per Page Records
	self.per_page = 10

	## Record every version of create, update, and destroy
	has_paper_trail

	## Override Friendly ID Method for generating slug
	def normalize_friendly_id(string)
		project_count = Project.where("project_name LIKE ?", "#{project_name}%").count
		if project_count > 0
	  	super.gsub("-", "_") + project_count.to_s
	  else
	  	super.gsub("-", "_")
	  end
	end

	## Class Methods
	def self.get_project(project_slug, user_id)
		self.where(slug: project_slug, user_id: user_id).eager_load(:building).order("projects.id ASC").first
	end

	def self.completed_projects(user_id, page)
		self.where(user_id: user_id, report: true).eager_load(:building).paginate(page: page).order("projects.id DESC")
	end

	def self.pending_projects(user_id, page)
		self.where(user_id: user_id, report: false).eager_load(:building).paginate(page: page).order("projects.id DESC")
	end

	## Instance Methods
	def project_details?
		self.step_completed == 1 ? true : false
	end

	def building_data?
		self.step_completed == 2 ? true : false
	end

	def building_services?
		self.step_completed == 3 ? true : false
	end

	def building_system?
		self.step_completed == 4 ? true : false
	end

	def building_type?
		self.step_completed == 5 ? true : false
	end

	def save_building_data_entries_info
		if building_type?
			link_budget_admin = LinkBudgetAdmin.last
			design_information_admin = DesignInformationAdmin.last
			if design_information_admin.present? && design_information_admin.maximum_antennas_per_bda.present?
				maximum_antennas_per_bda = design_information_admin.maximum_antennas_per_bda.to_f
			else
				maximum_antennas_per_bda = 14.0
			end
			equalization_multiplier = EqualizationMultiplier.last
			if equalization_multiplier.present? && equalization_multiplier.multiplied_factor.present?
				multiplied_factor = equalization_multiplier.multiplied_factor
			else
				multiplied_factor = 1
			end
			services_breakout = ServicesBreakout.where(number_of_services: self.number_of_services).last
			passive_component_loss = PassiveComponentLoss.last
			highest_frequency_band_id = HighestFrequencyBand.where(frequency: self.highest_frequency_band).last.try(:id)
			cable_loss_old = 0.0
			if highest_frequency_band_id.present?
				cable_loss_old = CableLoss.where(highest_frequency_band_id: highest_frequency_band_id).last.try(:cable_loss_1_by_2)
			end
			product_frequency_channel = self.product_frequency_channel
			coverage_area_per_bda = 0.0
			if product_frequency_channel.present?
				category_id = product_frequency_channel.bda_product_category.try(:id)
				coverage_area_per_bda = CoverageAreaPerBda.where(bda_product_category_id: category_id).last.try(:coverage_area)
			end
			report_material_lists = ReportMaterialList.eager_load(:donor_direct_feed_quantities, :fiber_material_quantities).order("report_material_lists.id ASC")

			building_data_entries = self.building.building_data_entries.eager_load(:system_dimension, :link_budget, :design_information, :part_quantity_informations).order("building_data_entries.id ASC")
			building_data_entries.each do |building_data_entry|
				system_dimension = building_data_entry.system_dimension
				## Save Link Budget Start
				channel_power = 0.0
				if product_frequency_channel.present?
					channel_power = ((product_frequency_channel.composite_power - 10 * (Math.log10(product_frequency_channel.number_of_channels))) - self.papr).round(1)
				end

				cable_length = 0.0
				antenna_gain = 0.0
				dl_margin = 0.0
				if link_budget_admin.present?
					cable_length = link_budget_admin.try(:cable_length)
					antenna_gain = link_budget_admin.try(:antenna_gain)
					dl_margin = link_budget_admin.try(:dl_margin)
				end

				cable_loss = cable_loss_old * cable_length

				splitter_loss = 0.0
				jumper_loss = 0.0
				connector_loss = 0.0
				if passive_component_loss.present?
					splitter_loss = passive_component_loss.quantity_of_splitters * passive_component_loss.try(passive_component_loss.type_of_splitter.to_sym)
					jumper_loss = passive_component_loss.try(:jumper_loss)
					connector_loss = passive_component_loss.try(:connector_loss)
				end

				antenna_erp = channel_power - cable_loss - splitter_loss - jumper_loss - connector_loss + antenna_gain

				allowed_pl = (20 * Math.log10(system_dimension.estimated_path_distance)) + (20 * Math.log10(system_dimension.frequency)) + 32.45

				rssi_at_portable = antenna_erp - dl_margin - allowed_pl

				estimated_path_loss = allowed_pl
				antenna_coverage_radius = (10 ** ((estimated_path_loss - 32.5 - (20 * Math.log10(building_data_entry.frequency))) / (10 * building_data_entry.building_slope))) * 3.2308

				building_data_entry.build_link_budget(channel_power: channel_power, cable_length: cable_length, cable_loss: cable_loss, splitter_loss: splitter_loss, jumper_loss: jumper_loss, connector_loss: connector_loss, antenna_gain: antenna_gain, antenna_erp: antenna_erp, dl_margin: dl_margin, allowed_pl: allowed_pl, rssi_at_portable: rssi_at_portable).save
				## Save Link Budget End

				building_data_entry.update_column(:antenna_coverage_radius, antenna_coverage_radius)
				building_data_entry.update_column(:estimated_path_loss, estimated_path_loss)

				## Save Design Information Start
				design_frequency = system_dimension.frequency

				coverage_radius = building_data_entry.antenna_coverage_radius

				coverage_area_per_antenna = 3.1415927 * (coverage_radius ** 2)

				building_total_coverage_area = 0.0
				if building_data_entry.area_this_floor.present?
					building_total_coverage_area = building_data_entry.area_this_floor
				elsif building_data_entry.total_area_building.present?
					building_total_coverage_area = building_data_entry.total_area_building / building_data_entry.number_of_floors
				end

				total_number_of_antennas = building_total_coverage_area / coverage_area_per_antenna
				if total_number_of_antennas < 1
					total_number_of_antennas = 1
				else
					total_number_of_antennas = total_number_of_antennas.round
				end

				number_of_floors = 1
				unless building_data_entry.floor_number.present?
					number_of_floors = building_data_entry.number_of_floors
				end

				number_of_antennas = total_number_of_antennas * number_of_floors
				if number_of_antennas < 1
					number_of_antennas = 1
				else
					number_of_antennas = number_of_antennas.round
				end

				cable_length = 0.0
				if link_budget_admin.present?
					cable_length = link_budget_admin.try(:cable_length)
				end
				horizontal_cable = cable_length * number_of_antennas

				number_of_bda = (number_of_floors * building_total_coverage_area) / coverage_area_per_bda
				if number_of_bda < 1
					number_of_bda = 1
				else
					number_of_bda = number_of_bda.round
				end

				distance_each_floor = 0.0
				if design_information_admin.present?
					distance_each_floor = design_information_admin.try(:distance_between_each_floor)
				end

				if number_of_floors > 1
					vertical_cable = distance_each_floor * (number_of_floors - 1)
				else
					vertical_cable = distance_each_floor
				end

				building_data_entry.build_design_information(design_frequency: design_frequency, coverage_radius: coverage_radius, coverage_area_per_antenna: coverage_area_per_antenna, building_total_coverage_area: building_total_coverage_area, number_of_antennas: number_of_antennas, horizontal_cable: horizontal_cable, number_of_bda: number_of_bda, total_number_of_antennas: total_number_of_antennas, number_of_floors: number_of_floors, distance_each_floor: distance_each_floor, vertical_cable: vertical_cable, coverage_area_per_bda: coverage_area_per_bda).save
				## Save Design Information End

				## Save Part Quantity Information Start
				design_information = building_data_entry.design_information
				number_of_bda = design_information.number_of_bda
				number_of_antennas = design_information.number_of_antennas
				if number_of_antennas < number_of_bda
					number_of_antennas = number_of_bda * multiplied_factor
				end
	  		number_of_antennas_per_bda = (number_of_antennas / number_of_bda).round
				## Recalculate values of Design Information DB23
				if number_of_antennas_per_bda > maximum_antennas_per_bda
					initial_number_of_bda = number_of_bda
		  		while (number_of_antennas_per_bda > maximum_antennas_per_bda)
					  number_of_bda, number_of_antennas_per_bda = check_number_of_antennas(number_of_antennas, number_of_antennas_per_bda, number_of_bda, initial_number_of_bda, maximum_antennas_per_bda)
					end
					number_of_antennas = number_of_antennas_per_bda * number_of_bda

					cable_length = 0.0
					if link_budget_admin.present?
						cable_length = link_budget_admin.try(:cable_length)
					end
					horizontal_cable = cable_length * number_of_antennas

					design_information.update(number_of_antennas: number_of_antennas, horizontal_cable: horizontal_cable, number_of_bda: number_of_bda)
				end
	  		splitter_matrix = SplitterMatrix.where(antennas: number_of_antennas_per_bda, number_of_bdas: design_information.number_of_bda).last

				report_material_lists.each do |report_material_list|
					save = false
					quantity = 0
		  		donor_direct_feed_quantity = report_material_list.donor_direct_feed_quantities.last
		  		fiber_material_quantity = report_material_list.fiber_material_quantities.last
					
					## IN-BUILDING DAS
			  	if (report_material_list.description == "1/2 inch plenum rated coaxial cable (ft)") && (report_material_list.material_category_id == 1)
			  		quantity = design_information.horizontal_cable + design_information.vertical_cable
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "2 way splitters (broadband), N-type connectors" && (report_material_list.material_category_id == 1)
			  		if splitter_matrix.present?
			  			quantity = splitter_matrix.product_type_2w * design_information.number_of_bda
			  		end
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "3 way splitters (broadband), N-type connectors" && (report_material_list.material_category_id == 1)
			  		if splitter_matrix.present?
			  			quantity = splitter_matrix.product_type_3w * design_information.number_of_bda
			  		end
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "4 way splitters (broadband), N-type connectors" && (report_material_list.material_category_id == 1)
			  		if splitter_matrix.present?
			  			quantity = splitter_matrix.product_type_4w * design_information.number_of_bda
			  		end
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Directional Coupler (broadband), N-type connectors" && (report_material_list.material_category_id == 1)
			  		if splitter_matrix.present?
			  			quantity = splitter_matrix.dc * design_information.number_of_bda
			  		end
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Crossband Coupler, N-type connectors" && (report_material_list.material_category_id == 1) && (self.number_of_services < 3)
			  		if self.number_of_services < 2
			  			quantity = 0
							save = false
			  		elsif self.number_of_services == 2
			  			quantity = design_information.number_of_bda + self.number_of_services
							save = true
			  		end
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
			  	elsif report_material_list.description ==  "Hybrid Combiner, N-type connectors" && (report_material_list.material_category_id == 1)
			  		quantity = 0
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
			  		save = false
			  	elsif report_material_list.description ==  "Custom Built Filtering, N-type connectors" && (report_material_list.material_category_id == 1) && (self.number_of_services >= 3)
			  		quantity = design_information.number_of_bda + self.number_of_services
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif (report_material_list.description == "Coaxial RF jumpers, plenum rated, N-Male Connectors (3ft)") && (report_material_list.material_category_id == 1)
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
	  				if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif (report_material_list.description == "N-Male Connectors (for 1/2 inch plenum rated coaxial cable)") && (report_material_list.material_category_id == 1)
			  		quantity = (2 * design_information.number_of_antennas) + 1
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "InBuilding Antenna (broadband), N-type connectors" && (report_material_list.material_category_id == 1)
			  		quantity = design_information.number_of_antennas
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true

					## BI-DIRECTIONAL AMP
			  	elsif report_material_list.description == "Low Power (1 Watt Composite Power) BDA Unit Connected to DAS" && (report_material_list.material_category_id == 2) && (self.product_frequency_channel.try(:bda_product_category).try(:id) == 1)
						quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
						if quantity < 1
							quantity = 1
						end
						if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Medium Power (2 Watts Composite Power) BDA Unit Connected to DAS" && (report_material_list.material_category_id == 2) && (self.product_frequency_channel.try(:bda_product_category).try(:id) == 2)
						quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
						if quantity < 1
							quantity = 1
						end
						if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "High Power (5 Watts Composite Power) BDA Unit Connected to DAS" && (report_material_list.material_category_id == 2) && (self.product_frequency_channel.try(:bda_product_category).try(:id) == 3)
						quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
						if quantity < 1
							quantity = 1
						end
						if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Medium Power (2 Watts Composite Power) BDA Unit Connected to OFF-AIR DONOR" && (report_material_list.material_category_id == 2) && (self.system_feed_method == "Off-Air")
						quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
	  				if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true

					## DIRECT FEED
			  	elsif report_material_list.description == "Base Station Interface (Point of Interconnect)" && (report_material_list.material_category_id == 3) && (self.system_feed_method == "Direct Feed")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif (report_material_list.description == "Hybrid Combiner, N-type connectors") && (report_material_list.material_category_id == 3) && (self.system_feed_method == "Direct Feed")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif (report_material_list.description == "Custom Built Filtering, N-type connectors") && (report_material_list.material_category_id == 3) && (self.system_feed_method == "Direct Feed")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true

					## FIBER OPTIC
			  	elsif report_material_list.description == "Master Fiber Optic Transceiver (Single Port)" && (report_material_list.material_category_id == 4) && (self.system_architecture == "Fiber and Coax")
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
			  		quantity = fiber_material_quantity.quantity * quantity
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Master Fiber Optic Transceiver (8 Fiber Optic Ports)" && (report_material_list.material_category_id == 4) && (self.system_architecture == "Fiber and Coax")
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
			  		quantity = fiber_material_quantity.quantity * quantity
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Slave Fiber Optic Transceiver (Single Port)" && (report_material_list.material_category_id == 4) && (self.system_architecture == "Fiber and Coax")
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
			  		quantity = fiber_material_quantity.quantity * quantity
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
			  		save = true
			  	elsif report_material_list.description == "Fiber Optic Jumpers (10ft)" && (report_material_list.material_category_id == 4) && (self.system_architecture == "Fiber and Coax")
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
						quantity = fiber_material_quantity.quantity * quantity
						if quantity < 1
							quantity = 2 * 1
						else
							quantity = 2 * quantity
						end
						if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						save = true
			  	elsif report_material_list.description == "Fiber Optic Backbone Cable (ft)" && (report_material_list.material_category_id == 4) && (self.system_architecture == "Fiber and Coax")
			  		quantity = design_information.number_of_bda
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_das
							quantity = bda_quantity_multiplier * quantity
	  				end
			  		quantity = design_information.vertical_cable * design_information.number_of_floors * quantity
			  		if self.communication_type.downcase == "simplex"
							quantity = quantity * 2
						end
						quantity = fiber_material_quantity.quantity * quantity
			  		save = true

					## OFF-AIR DONOR
			  	elsif report_material_list.description == "Off-air donor antenna, Yagi, minimum 10dBi Gain" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
	  				quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "DC Block Donor, Coaxial Line Protector (N-Female connectors)" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "1/2 inch Off-air donor antenna cable (ft)" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "N-Male connectors for off-air donor antenna cables" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "Ground Kit for 1/2 inch Coax (for off-air donor antenna cable outer conductor)" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "Universal Weatherproofing Kit (for off-air donor antenna cable connectors)" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	elsif report_material_list.description == "Prep Tool for 1/2 inch donor cable (all-in-one strip tool)" && (report_material_list.material_category_id == 5) && (self.system_feed_method == "Off-Air")
			  		quantity = self.number_of_services
						if (self.number_of_services >= 3) && (self.number_of_services <= 20) && services_breakout.present?
							bda_quantity_multiplier = services_breakout.number_of_bdas_donor
							quantity = bda_quantity_multiplier
	  				end
			  		quantity = quantity * donor_direct_feed_quantity.quantity
						save = true
			  	end

			  	if quantity.present?
			  		quantity = quantity.round
			  	end
			  	if save && (quantity > 0)
						building_data_entry.part_quantity_informations.create(report_material_list_id: report_material_list.id, quantity: quantity)
					end
				end
				## Save Part Quantity Information End
			end
		end
	end

	def check_number_of_antennas(number_of_antennas, number_of_antennas_per_bda, number_of_bda, initial_number_of_bda, maximum_antennas_per_bda)
		bda_multiplier = number_of_antennas_per_bda / maximum_antennas_per_bda
		if bda_multiplier.round == bda_multiplier.ceil
			bda_multiplier = bda_multiplier.round
		else
			bda_multiplier = bda_multiplier.round + 0.5
		end
		number_of_bda = bda_multiplier * initial_number_of_bda
		number_of_antennas_per_bda = (number_of_antennas / number_of_bda).round
		return number_of_bda, number_of_antennas_per_bda
	end

	def send_admin_email
		if self.report?
			ProjectMailer.delay.email_admin(self)
		end
	end
end
