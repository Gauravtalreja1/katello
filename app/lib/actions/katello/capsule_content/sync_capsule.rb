module Actions
  module Katello
    module CapsuleContent
      class SyncCapsule < ::Actions::EntryAction
        include Actions::Katello::PulpSelector
        def plan(smart_proxy, options = {})
          plan_self(:smart_proxy_id => smart_proxy.id, :options => options)
          action_subject(smart_proxy)
          environment = options[:environment]
          content_view = options[:content_view]
          repository = options[:repository]
          skip_metadata_check = options.fetch(:skip_metadata_check, false)
          sequence do
            repos = repos_to_sync(smart_proxy, environment, content_view, repository, skip_metadata_check)

            repos.in_groups_of(Setting[:foreman_proxy_content_batch_size], false) do |repo_batch|
              concurrence do
                repo_batch.each do |repo|
                  plan_pulp_action(
                    [Actions::Pulp::Orchestration::Repository::SmartProxySync,
                     Actions::Pulp3::CapsuleContent::Sync],
                                     repo, smart_proxy,
                                     skip_metadata_check: skip_metadata_check)
                end
              end

              concurrence do
                repo_batch.each do |repo|
                  if repo.is_a?(::Katello::Repository) &&
                      repo.distribution_bootable? &&
                      repo.download_policy == ::Runcible::Models::YumImporter::DOWNLOAD_ON_DEMAND
                    plan_action(Katello::Repository::FetchPxeFiles,
                                id: repo.id,
                                capsule_id: smart_proxy.id)
                  end
                end
              end
            end
          end
        end

        def repos_to_sync(smart_proxy, environment, content_view, repository, skip_metatadata_check = false)
          smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
          smart_proxy_helper.lifecycle_environment_check(environment, repository)
          if repository
            if skip_metatadata_check || !repository.smart_proxy_sync_histories.where(:smart_proxy_id => smart_proxy).any? { |sph| !sph.finished_at.nil? }
              [repository]
            end
          else
            repositories = smart_proxy_helper.repositories_available_to_capsule(environment, content_view).by_rpm_count
            repositories_to_skip = []
            if skip_metatadata_check
              smart_proxy_helper.clear_smart_proxy_sync_histories repositories
            else
              repositories_to_skip = ::Katello::Repository.synced_on_capsule smart_proxy
            end
            repositories - repositories_to_skip
          end
        end

        def resource_locks
          :link
        end

        def run
          smart_proxy = ::SmartProxy.find(input[:smart_proxy_id])
          smart_proxy.sync_container_gateway
        end

        def rescue_strategy
          Dynflow::Action::Rescue::Skip
        end
      end
    end
  end
end
