module Actions
  module Pulp3
    module Repository
      class SaveVersion < Pulp3::Abstract
        def plan(repository, options = {})
          fail "Cannot accept tasks and repository_details into Save Version." if options[:tasks].present? && options[:repository_details].present?
          plan_self(:repository_id => repository.id, :tasks => options[:tasks], :repository_details => options[:repository_details], :force_fetch_version => options.fetch(:force_fetch_version, false))
        end

        def run
          repo = ::Katello::Repository.find(input[:repository_id])
          if input[:force_fetch_version]
            version_href = fetch_version_href(repo)
          elsif input[:repository_details].present?
            version_href = input[:repository_details][:latest_version_href]
          elsif input[:tasks].present?
            version_href = ::Katello::Pulp3::Task.version_href(input[:tasks])
          else
            version_href = fetch_version_href(repo)
          end

          output[:publication_provided] = false
          if input[:tasks].present?
            if (publication_href = ::Katello::Pulp3::Task.publication_href(input[:tasks]))
              repo.update(:publication_href => publication_href)
              output[:publication_provided] = true
            end
          end

          if version_href
            if repo.version_href != version_href || input[:force_fetch_version]
              output[:contents_changed] = true
              repo.update(:last_contents_changed => DateTime.now)
              repo.update(:version_href => version_href)
            end
          else
            output[:contents_changed] = false
          end
        end

        def fetch_version_href(repo)
          # Fetch latest Pulp 3 repo version
          repo_backend_service = repo.backend_service(SmartProxy.pulp_primary)
          repo_href = repo_backend_service.repository_reference.repository_href
          repo_backend_service.api.repositories_api.read(repo_href).latest_version_href
        end
      end
    end
  end
end
