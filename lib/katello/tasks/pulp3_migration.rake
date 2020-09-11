load "#{Katello::Engine.root}/lib/katello/tasks/common.rake"

namespace :katello do
  desc "Runs a Pulp 2 to 3 Content Migration for supported types.  May be run multiple times.  Use wait=false to immediately return with a task url."
  task :pulp3_migration => ["environment", "disable_dynflow", "check_ping"] do
    task = ForemanTasks.async_task(Actions::Pulp3::ContentMigration, SmartProxy.pulp_primary, reimport_all: ENV['reimport_all'])

    if ENV['wait'].nil? || ::Foreman::Cast.to_bool(ENV['wait'])
      until !task.pending? || task.paused?
        sleep(20)
        task = ForemanTasks::Task.find(task.id)
      end

      if task.result == 'warning' || task.result == 'pending'
        msg = _("Migration failed, You will want to investigate: https://#{Socket.gethostname}/foreman_tasks/tasks/#{task.id}\n")
        $stderr.print(msg)
        fail ForemanTasks::TaskError, task
      else
        puts _("Content Migration completed successfully")
      end
    else
      puts "Migration started, you may monitor it at: https://#{Socket.gethostname}/foreman_tasks/tasks/#{task.id}"
    end
  end
end
