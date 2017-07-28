namespace :db do
	desc "Dumps the Database."
	task dump: :environment do
		begin
			Dir.chdir(File.join(Rails.root.to_s, "public"))
			Dir.mkdir("psql_db_backup") unless File.directory?("psql_db_backup") 
			cmd = nil
	    with_config do |app, host, database, user, password|
				cmd = "PGPASSWORD=#{password} pg_dump --host #{host} --username #{user} #{database} > #{Rails.root}/public/psql_db_backup/#{app}.sql"
	    end
			exec cmd
			puts "Database Dump(#{DateTime.now.in_time_zone})"
			Rails.logger.info "Database Dump(#{DateTime.now.in_time_zone})"
		rescue => e
			puts "Database Dump(#{DateTime.now.in_time_zone}): #{e}"
			Rails.logger.info "Database Dump(#{DateTime.now.in_time_zone}): #{e}"
		end
	end
	
	desc "Restores the Database."
  task restore: :environment do
		begin
	    cmd = nil
	    with_config do |app, host, database, user, password|
	      cmd = "PGPASSWORD=#{password} psql --host #{host} --username #{user} -d #{database} < #{Rails.root}/public/psql_db_backup/#{app}.sql"
	    end
	    Rake::Task["db:drop"].invoke
	    Rake::Task["db:create"].invoke
	    exec cmd
			puts "Restore Dump(#{DateTime.now.in_time_zone})"
			Rails.logger.info "Restore Dump(#{DateTime.now.in_time_zone})"
		rescue => e
			puts "Restore Dump(#{DateTime.now.in_time_zone}): #{e}"
			Rails.logger.info "Restore Dump(#{DateTime.now.in_time_zone}): #{e}"
		end
	end
	
	private

  def with_config
    yield Rails.application.class.parent_name.underscore,
      ActiveRecord::Base.connection_config[:host],
      ActiveRecord::Base.connection_config[:database],
			ActiveRecord::Base.connection_config[:username],
      ActiveRecord::Base.connection_config[:password]
	end
end

# 0 0 * * 0 /bin/bash -l -c 'cd {app_path} && RAILS_ENV=production bundle exec rake db:dump --silent >> log/cron_log.log 2>&1'
