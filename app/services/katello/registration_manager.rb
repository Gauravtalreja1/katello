module Katello
  class RegistrationManager
    class << self
      private :new
      delegate :propose_existing_hostname, :new_host_from_facts, to: Katello::Host::SubscriptionFacet

      def determine_organization(content_view_environment, activation_key)
        content_view_environment.try(:environment).try(:organization) || activation_key.try(:organization)
      end

      def determine_host_dmi_uuid(rhsm_params)
        host_uuid = rhsm_params.dig(:facts, 'dmi.system.uuid')

        if Katello::Host::SubscriptionFacet.override_dmi_uuid?(host_uuid)
          return [SecureRandom.uuid, true]
        end

        [host_uuid, false]
      end

      def process_registration(rhsm_params, content_view_environment, activation_keys = [])
        host_name = propose_existing_hostname(rhsm_params[:facts])
        host_uuid, host_uuid_overridden = determine_host_dmi_uuid(rhsm_params)

        rhsm_params[:facts]['dmi.system.uuid'] = host_uuid # ensure we find & validate against a potentially overridden UUID

        organization = determine_organization(content_view_environment, activation_keys.first)

        hosts = find_existing_hosts(host_name, host_uuid)

        validate_hosts(hosts, organization, host_name, host_uuid, host_uuid_overridden)

        host = hosts.first || new_host_from_facts(
          rhsm_params[:facts],
          organization,
          Location.default_host_subscribe_location!
        )
        host.organization = organization unless host.organization

        register_host(host, rhsm_params, content_view_environment, activation_keys)

        if host_uuid_overridden
          host.subscription_facet.update_dmi_uuid_override(host_uuid)
        end

        host
      end

      def dmi_uuid_allowed_dups
        Katello::Host::SubscriptionFacet::DMI_UUID_ALLOWED_DUPS
      end

      def dmi_uuid_change_allowed?(host, host_uuid_overridden)
        if host_uuid_overridden
          true
        elsif host.build && Setting[:host_profile_assume_build_can_change]
          true
        else
          Setting[:host_profile_assume]
        end
      end

      def find_existing_hosts(host_name, host_uuid)
        query = ::Host.unscoped.where("#{::Host.table_name}.name = ?", host_name)

        unless host_uuid.nil? || dmi_uuid_allowed_dups.include?(host_uuid) # no need to include the dmi uuid lookup
          query = query.left_outer_joins(:subscription_facet).or(::Host.unscoped.left_outer_joins(:subscription_facet)
            .where("#{Katello::Host::SubscriptionFacet.table_name}.dmi_uuid = ?", host_uuid)).distinct
        end

        query
      end

      def validate_hosts(hosts, organization, host_name, host_uuid, host_uuid_overridden = false)
        return if hosts.empty?

        hosts = hosts.where(organization_id: [organization.id, nil])
        hosts_size = hosts.size

        if hosts_size == 0 # not in the correct org
          #TODO: http://projects.theforeman.org/issues/11532
          registration_error("Host with name %{host_name} is currently registered to a different org, please migrate host to %{org_name}.",
                             org_name: organization.name, host_name: host_name)
        end

        if hosts_size == 1
          host = hosts.first

          if host.name == host_name
            if !host.build && Setting[:host_re_register_build_only]
              registration_error("Host with name %{host_name} is currently registered but not in build mode (host_re_register_build_only==True). Unregister the host manually or put it into build mode to continue.", host_name: host_name)
            end

            current_dmi_uuid = host.subscription_facet&.dmi_uuid
            dmi_uuid_changed = current_dmi_uuid && current_dmi_uuid != host_uuid
            if dmi_uuid_changed && !dmi_uuid_change_allowed?(host, host_uuid_overridden)
              registration_error("This host is reporting a DMI UUID that differs from the existing registration.")
            end

            return true
          end
        end

        hosts = hosts.where.not(name: host_name)
        registration_error("The DMI UUID of this host (%{uuid}) matches other registered hosts: %{existing}", uuid: host_uuid, existing: joined_hostnames(hosts))
      end

      def registration_error(message, meta = {})
        fail(Katello::Errors::RegistrationError, _(message) % meta)
      end

      def joined_hostnames(hosts)
        hosts.pluck(:name).sort.join(', ')
      end

      # options:
      #  * organization_destroy: destroy some data associated with host, but
      #    leave items alone that will be removed later as part of org destroy
      #  * unregistering: unregister the host but don't destroy it
      def unregister_host(host, options = {})
        organization_destroy = options.fetch(:organization_destroy, false)
        unregistering = options.fetch(:unregistering, false)

        # if the first operation fails, just raise the error since there's nothing to clean up yet.
        candlepin_consumer_destroy(host.subscription_facet.uuid) if !organization_destroy && host.subscription_facet.try(:uuid)

        # if this fails, there is not much to do about it right now. We can't really re-create the candlepin consumer.
        # This can be cleaned up later via clean_backend_objects.

        delete_agent_queue(host) if host.content_facet.try(:uuid)

        host.subscription_facet.try(:destroy!)

        if unregistering
          remove_host_artifacts(host)
        elsif organization_destroy
          host.content_facet.try(:destroy!)
          remove_host_artifacts(host, false)
        else
          host.content_facet.try(:destroy!)
          destroy_host_record(host.id)
        end
      end

      def register_host(host, consumer_params, content_view_environment, activation_keys = [])
        new_host = host.new_record?

        unless new_host
          host.save!
          unregister_host(host, :unregistering => true)
          host.reload
        end

        unless activation_keys.empty?
          content_view_environment ||= lookup_content_view_environment(activation_keys)
          set_host_collections(host, activation_keys)
        end
        fail _('Content View and Environment not set for registration.') if content_view_environment.nil?

        host.save! #the host is in foreman db at this point

        host_uuid = get_uuid(consumer_params)
        consumer_params[:uuid] = host_uuid
        host.content_facet = populate_content_facet(host, content_view_environment, host_uuid)
        host.subscription_facet = populate_subscription_facet(host, activation_keys, consumer_params, host_uuid)
        host.save! # the host has content and subscription facets at this point
        create_initial_subscription_status(host)

        User.as_anonymous_admin do
          begin
            create_in_candlepin(host, content_view_environment, consumer_params, activation_keys)
          rescue StandardError => e
            # we can't call CP here since something bad already happened. Just clean up our DB as best as we can.
            host.subscription_facet.try(:destroy!)
            new_host ? remove_partially_registered_new_host(host) : remove_host_artifacts(host)
            raise e
          end

          finalize_registration(host)
        end
      end

      def check_registration_services
        ping_results = {}
        User.as_anonymous_admin do
          ping_results = Katello::Ping.ping
        end
        candlepin_ok = ping_results[:services][:candlepin][:status] == "ok"
        candlepin_ok
      end

      private

      def destroy_host_record(host_id)
        host = ::Host.find(host_id)
        host.destroy
      rescue ActiveRecord::RecordNotFound
        Rails.logger.warn("Attempted to destroy host %s but host is already gone." % host_id)
      end

      def get_uuid(params)
        params.key?(:uuid) ? params[:uuid] : SecureRandom.uuid
      end

      def remove_partially_registered_new_host(host)
        host.content_facet.try(:destroy!)
        destroy_host_record(host.id)
      end

      def create_initial_subscription_status(host)
        host.subscription_facet.update_subscription_status(::Katello::SubscriptionStatus::UNKNOWN)
      end

      def create_in_candlepin(host, content_view_environment, consumer_params, activation_keys)
        # if CP fails, nothing to clean up yet w.r.t. backend services
        cp_create = ::Katello::Resources::Candlepin::Consumer.create(content_view_environment.cp_id, consumer_params, activation_keys.map(&:cp_name))
        ::Katello::Host::SubscriptionFacet.update_facts(host, consumer_params[:facts]) unless consumer_params[:facts].blank?
        cp_create[:uuid]
      end

      def finalize_registration(host)
        host = ::Host.find(host.id)
        host.subscription_facet.update_from_consumer_attributes(host.subscription_facet.candlepin_consumer.
            consumer_attributes.except(:guestIds, :facts))
        host.subscription_facet.save!
        host.subscription_facet.update_subscription_status
        host.content_facet.update_errata_status
        host.refresh_global_status!
      end

      def set_host_collections(host, activation_keys)
        host_collection_ids = activation_keys.flat_map(&:host_collection_ids).compact.uniq

        host_collection_ids.each do |host_collection_id|
          host_collection = ::Katello::HostCollection.find(host_collection_id)
          if !host_collection.unlimited_hosts && host_collection.max_hosts >= 0 &&
             host_collection.systems.length >= host_collection.max_hosts
            fail _("Host collection '%{name}' exceeds maximum usage limit of '%{limit}'") %
                     {:limit => host_collection.max_hosts, :name => host_collection.name}
          end
        end
        host.host_collection_ids = host_collection_ids
      end

      def lookup_content_view_environment(activation_keys)
        activation_key = activation_keys.reverse.detect do |act_key|
          act_key.environment && act_key.content_view
        end
        if activation_key
          ::Katello::ContentViewEnvironment.where(:content_view_id => activation_key.content_view, :environment_id => activation_key.environment).first
        else
          fail _('At least one activation key must have a lifecycle environment and content view assigned to it')
        end
      end

      def candlepin_consumer_destroy(host_uuid)
        ::Katello::Resources::Candlepin::Consumer.destroy(host_uuid)
      rescue RestClient::ResourceNotFound
        Rails.logger.warn(_("Attempted to destroy consumer %s from candlepin, but consumer does not exist in candlepin") % host_uuid)
      rescue RestClient::Gone
        Rails.logger.warn(_("Candlepin consumer %s has already been removed") % host_uuid)
      end

      def delete_agent_queue(host)
        return unless ::Katello.with_katello_agent?

        queue_name = Katello::Agent::Dispatcher.host_queue_name(host)
        Katello::EventQueue.push_event(::Katello::Events::DeleteHostAgentQueue::EVENT_TYPE, host.id) do |attrs|
          attrs[:metadata] = { queue_name: queue_name }
          attrs[:process_after] = 10.minutes.from_now
        end
      end

      def populate_content_facet(host, content_view_environment, uuid)
        content_facet = host.content_facet || ::Katello::Host::ContentFacet.new(:host => host)
        content_facet.content_view = content_view_environment.content_view
        content_facet.lifecycle_environment = content_view_environment.environment
        content_facet.uuid = uuid
        content_facet.save!
        content_facet
      end

      def populate_subscription_facet(host, activation_keys, consumer_params, uuid)
        subscription_facet = host.subscription_facet || ::Katello::Host::SubscriptionFacet.new(:host => host)
        subscription_facet.last_checkin = Time.now
        subscription_facet.update_from_consumer_attributes(consumer_params.except(:guestIds))
        subscription_facet.uuid = uuid
        subscription_facet.user = User.current unless User.current.nil? || User.current.hidden?
        subscription_facet.save!
        subscription_facet.activation_keys = activation_keys
        subscription_facet
      end

      def remove_host_artifacts(host, clear_content_facet = true)
        if host.content_facet && clear_content_facet
          host.content_facet.bound_repositories = []
          host.content_facet.applicable_errata = []
          host.content_facet.uuid = nil
          host.content_facet.save!
        end

        host.get_status(::Katello::ErrataStatus).destroy
        host.get_status(::Katello::PurposeSlaStatus).destroy
        host.get_status(::Katello::PurposeRoleStatus).destroy
        host.get_status(::Katello::PurposeUsageStatus).destroy
        host.get_status(::Katello::PurposeAddonsStatus).destroy
        host.get_status(::Katello::PurposeStatus).destroy
        host.get_status(::Katello::SubscriptionStatus).destroy
        host.get_status(::Katello::TraceStatus).destroy
        host.installed_packages.delete_all

        host.rhsm_fact_values.delete_all
      end
    end
  end
end
